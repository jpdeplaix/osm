(* OSM tools
 * Copyright (C) 2013 Jérôme Vouillon
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, with linking exception;
 * either version 2.1 of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
 *)

(*

* Redesign R-tree of linear features

  mostly constant:
    layer         4 bits
    bridge/tunnel 2 bit

  category    5 bits
  oneway/access 5 bits (car 2, bikes 2, pedestrian 1)
  ==> 2 bytes => 6 bits remaining for the number of ways

* Rendering performance:
  * do not render railway=rail;service=* at low zoom levels
  * multiple surface R-trees:
    R-tree of small surfaces; R-tree of other surfaces;
    R-tree with about the 1% largest surfaces; ...

* Rendering fixes
  ==> Highway with area=yes
      ==> do not draw them as ways as well
  ==> Outline of highway surfaces
  ==> Notre Dame de Paris and Sacré Coeur are missing!
      ==> use same algorithm as osm2pgsql to deal with multipolygon tags

* We could improve the rendering of tunnels, ... by classifying nodes:
  - do not use round linecap at tunnel extremities
  - draw additional circles when a path extremities do not agree
  - detect nodes with level mismatch

* One-way arrows (foot, bicycle, car), accessibility (foot, bicycle, car)
  ===> share between ways!
*)

let async_zoom = true
let async_zoom_in = true
let async_delay = 50 (*ms*)

let debug_time = true

let _ = Printexc.record_backtrace true

let _ = Column.set_database "/tmp/osm"

let (>>) x f = f x

(****)

(*XXX Duplicated code...*)

let sint_of_int i = let i' = i lsr 1 in if i land 1 = 1 then (-i' - 1) else i'

let rec read_varint_rec a p v offs =
  let i = !p in
  let c = Char.code a.[i] in
  incr p;
  if c >= 0x80 then
    read_varint_rec a p (v lor ((c land 0x7f) lsl offs)) (offs + 7)
  else
    v lor (c lsl offs)

let read_varint a p = read_varint_rec a p 0 0

let read_signed_varint a p = sint_of_int (read_varint a p)

let read_int_2 s pos = Char.code s.[pos] lor (Char.code s.[pos + 1] lsl 8)

(****)

let rec log2 x = if x <= 1 then 0 else 1 + log2 (x lsr 1)
let log2_tbl = Array.init 256 log2
let log2_16 x =
  let x' = x lsr 8 in
  if x' = 0 then
    Array.unsafe_get log2_tbl x
  else
    8 + Array.unsafe_get log2_tbl x'
let log2_32 x =
  let x' = x lsr 16 in
  if x' = 0 then log2_16 x else 16 + log2_16 x'
let log2 x =
  let x' = x lsr 32 in
  if x' = 0 then log2_32 x else 32 + log2_32 x'

(****)

module Surface = Category.Make (struct
  type t =
    [ `Water | `Forest | `Grass | `Farmland | `Residential | `Commercial
    | `Industrial | `Park | `Cemetery | `Parking | `Building
    | `Highway_residential | `Highway_unclassified | `Highway_living_street
    | `Highway_service | `Highway_pedestrian | `Highway_track
    | `Highway_footway | `Highway_path ]
  let list = 
    [ `Water; `Forest; `Grass; `Farmland; `Residential; `Commercial;
      `Industrial; `Park; `Cemetery; `Parking; `Building;
      `Highway_residential; `Highway_unclassified; `Highway_living_street;
      `Highway_service; `Highway_pedestrian; `Highway_track;
      `Highway_footway; `Highway_path ]
end)

module Linear_feature = Category.Make (struct
  type t =
    [ `Motorway | `Trunk | `Primary | `Secondary | `Tertiary
    | `Motorway_link | `Trunk_link | `Primary_link
    | `Secondary_link | `Tertiary_link
    | `Residential | `Unclassified | `Living_street | `Road | `Service
    | `Pedestrian | `Track | `Cycleway | `Bridleway | `Footway | `Path | `Steps
    | `Waterway
    | `Runway | `Taxiway
    | `Rail | `Tram | `Subway ]
  let list =
    [ `Motorway; `Trunk; `Primary; `Secondary; `Tertiary;
      `Motorway_link; `Trunk_link; `Primary_link;
      `Secondary_link; `Tertiary_link;
      `Residential; `Unclassified; `Living_street; `Road; `Service;
      `Pedestrian; `Track; `Cycleway; `Bridleway; `Footway; `Path; `Steps;
      `Waterway;
      `Runway; `Taxiway;
      `Rail; `Tram; `Subway ]
end)

let pedestrian_surface = Cairo.PNG.create "images/pedestrian.png"

(****)

module Bbox = Rtree.Bbox

type bbox = Bbox.t =
  { min_lat : int; max_lat : int; min_lon : int; max_lon : int }

let bounding_box ratio x_min y_min x_max y_max =
  let ratio = float ratio in
  let to_lat y = truncate (Geometry.y_to_lat (y *. 10_000_000.) /. ratio) in
  let to_lon x = truncate (x *. 10_000_000. /. ratio) in
  { min_lat = to_lat y_min; max_lat = to_lat y_max;
    min_lon = to_lon x_min; max_lon = to_lon x_max }

(****)

(* Old edge R-tree, now used only to find nodes for routing
   (should be eventually superseded by the R-tree containing
   linear features). *)

let leaf_size = 1024

let decode_leaf leaves i =
  let buf = String.create leaf_size in
  seek_in leaves (i * leaf_size);
  really_input leaves buf 0 leaf_size;
  let node_len = read_int_2 buf 0 in
  let edge_len = read_int_2 buf 2 in
  let node_lat = Array.make (node_len / 2) 0 in
  let node_lon = Array.make (node_len / 2) 0 in
  let node_idx = Array.make (node_len / 2) 0 in
  let edges = Array.make edge_len 0 in
  let i = ref 0 in
  let pos = ref 4 in
  let lat = ref 0 in
  let lon = ref 0 in
  let idx = ref 0 in
  while !pos < node_len + 4 do
    let v = !lat + read_signed_varint buf pos in
    node_lat.(!i) <- v;
    lat := v;
    let v = !lon + read_signed_varint buf pos in
    node_lon.(!i) <- v;
    lon := v;
    let v = !idx + read_signed_varint buf pos in
    node_idx.(!i) <- v;
    idx := v;
    incr i
  done;
  let node_lat = Array.sub node_lat 0 !i in
  let node_lon = Array.sub node_lon 0 !i in
  let node_idx = Array.sub node_idx 0 !i in
  let i = ref 0 in
  let node = ref 0 in
  while !pos < edge_len + node_len + 4 do
    let v = !node + read_signed_varint buf pos in
    edges.(!i) <- v;
    node := v;
    incr i
  done;
  let edges = Array.sub edges 0 !i in
  (node_lat, node_lon, node_idx, edges)

let clamp x min max = if x < min then min else if x > max then max else x

let to_deg x = x * 50

let distance_to_box bbox lat lon =
  let lat' = clamp lat (to_deg bbox.min_lat) (to_deg bbox.max_lat) in
  let lon' = clamp lon (to_deg bbox.min_lon) (to_deg bbox.max_lon) in
  Geometry.distance lat lon lat' lon'

let nearest_point =
  let (leaves, routine_nodes) =
    Rtree.open_in (Column.file_in_database "highway/r_tree") in
  let leaves = open_in leaves in
  Rtree.find_nearest_point routine_nodes distance_to_box
    (fun j lat lon ->
       let (node_lat, node_lon, node_idx, _) = decode_leaf leaves j in
       let i0 = ref 0 in
       let dist = ref max_int in
       for i = 0 to Array.length node_lat - 1 do
         let d =
           Geometry.distance lat lon (to_deg node_lat.(i)) (to_deg node_lon.(i))
         in
         if d < !dist then begin
           dist := d;
           i0 := i
         end
       done;
       if !dist = max_int then
         None
       else
         Some (!dist, (node_idx.(!i0), node_lat.(!i0), node_lon.(!i0))))

(****)

(*XXX Temp code: rebuild ways *)

let debug = false

type t = (bool ref * int) list

let initialize g =
  let g' = Array.make (Array.length g) [] in
  Array.iteri
    (fun i l ->
       List.iter
         (fun j ->
            let m = ref false in
            g'.(i) <- (m, j) :: g'.(i);
            g'.(j) <- (m, i) :: g'.(j))
         l)
    g;
  g'

let odd_degree g = (ref 0, Array.map (fun l -> (List.length l) land 1 = 1) g)

let rec next_node g i =
  match g.(i) with
    [] ->
      -1
  | (m, j) :: r ->
      g.(i) <- r;
      if !m then
        next_node g i
      else begin
        m := true;
        j
      end

let rec next_odd (i, o) =
  if !i = Array.length o then
    -1
  else if o.(!i) then begin
    o.(!i) <- false;
    !i
  end else begin
    incr i;
    next_odd (i, o)
  end

let rec find graph odd_deg i j cont lst =
  let k = next_node graph j in
if debug then Format.eprintf "Going from %d to %d@." j k;
  if k = -1 then begin
    if i = j then begin
if debug then Format.eprintf "Loop through %d@." i;
      (i :: cont, lst)
    end else begin
if debug then Format.eprintf "Path %d --> %d@." i j;
      (snd odd_deg).(j) <- false;
      let k = next_odd odd_deg in
if debug then Format.eprintf "Continuing from %d@." k;
      if k = -1 then
        ([j], lst)
      else begin
        let (path, lst) = find graph odd_deg i k cont lst in
        ([j], path :: lst)
      end
    end
  end else begin
    let (path, lst) = find graph odd_deg i k cont lst in
if debug then Format.eprintf "--@.";
    find graph odd_deg j j (path) lst
  end

let rec find_circuits graph odd_deg i lst =
  if i = Array.length graph then
    lst
  else begin
    let j = next_node graph i in
if debug then Format.eprintf "Circuit through %d-%d@." i j;
    if j = -1 then
      find_circuits graph odd_deg (i + 1) lst
    else
      let (path, lst) = find graph odd_deg i j [] lst in
      find_circuits graph odd_deg (i + 1) ((i :: path) :: lst)
  end

let rec find_unclosed_paths graph odd_deg lst =
  let i = next_odd odd_deg in
  if i <> -1 then begin
    let (path, lst) = find graph odd_deg i i [] lst in
    find_unclosed_paths graph odd_deg (path :: lst)
  end else
    lst

let find_paths graph =
  let graph = initialize graph in
  let odd_deg = odd_degree graph in
if debug then Format.eprintf "Finding unclosed paths@.";
  let lst = find_unclosed_paths graph odd_deg [] in
if debug then Format.eprintf "Finding circuits@.";
  find_circuits graph odd_deg 0 lst

let v = false

let num = ref 0
let miss = ref 0
let find_node tbl i =
  incr num;
  if not tbl.(i) then begin incr miss; tbl.(i) <- true end

let chunk tbl edges i l =
  let (_, _, _, _, (node_lat, node_lon)) = edges.(i) in
  let g = Array.make (Array.length node_lat) [] in
  for j = i to i + l - 1 do
    let (n1, n2, _, _, _) = edges.(j) in
    g.(n1) <- n2 :: g.(n1)
  done;
  let l = find_paths g in
List.iter (fun p -> List.iter (fun i -> find_node tbl i) p) l;
if v then
List.iter
  (fun p ->
    Format.eprintf "+ ";
    List.iter (fun n -> Format.eprintf "%d " n) p;
    Format.eprintf "@.")
    l;
  l

let build_paths edges =
  Array.sort
    (fun (_, _, cat, lay, _) (_, _, cat', lay', _) ->
       let c = compare cat cat' in
       if c <> 0 then c else
       compare lay lay')
    edges;
  let len = Array.length edges in
  let i0 = ref 0 in
  let prev_cat = ref (-1) in
  let prev_lay = ref (-1) in
  let (_, _, _, _, (x, y)) = edges.(0) in
  let tbl = Array.make (Array.length x) false in
  let paths = ref [] in
  for i = 0 to len - 1 do
    let (_, _, cat, lay, _) = edges.(i) in
    if (cat <> !prev_cat || lay <> !prev_lay) && i > !i0 then begin
      paths :=
        (!prev_cat, !prev_lay, chunk tbl edges !i0 (i - !i0)) :: !paths;
      i0 := i
    end;
    prev_cat := cat;
    prev_lay := lay
  done;
  paths :=
    (!prev_cat, !prev_lay, chunk tbl edges !i0 (len - !i0)) :: !paths;
if v then Format.eprintf "----@.";
  for i = 0 to Array.length tbl - 1 do
    assert (tbl.(i))
  done;
  Array.of_list
    (List.map
       (fun (cat, lay_info, l) ->
          (* Extract layer and perform sign extension *)
          let lay = (lay_info lsr 2) lxor 8 - 8 in
          ((cat, lay, lay_info land 1 = 1, lay_info land 2 = 2),
           List.map
             (fun p ->
               Array.of_list (List.map (fun i -> x.(i)) p),
               Array.of_list (List.map (fun i -> y.(i)) p))
             l))
       !paths)

(* R-tree containing linear features *)

let linear_ratio = 50

let (leaves, linear_rtree) =
  Rtree.open_in (Column.file_in_database "linear/rtree")
let leaves = open_in leaves

let decode_leaf i =
  let leaf_size = 2048 in
  let buf = String.create leaf_size in
  seek_in leaves (i * leaf_size);
  really_input leaves buf 0 leaf_size;

  let node_len = read_int_2 buf 0 in
  let x = Array.make (node_len / 2) 0. in
  let y = Array.make (node_len / 2) 0. in
  let i = ref 0 in
  let pos = ref 4 in
  let lat = ref 0 in
  let lon = ref 0 in
  while !pos < node_len + 4 do
    let v = !lat + read_signed_varint buf pos in
    y.(!i) <- Geometry.lat_to_y (float (v * linear_ratio));
    lat := v;
    let v = !lon + read_signed_varint buf pos in
    x.(!i) <- float (v * linear_ratio);
    lon := v;
    incr i
  done;
  let x = Array.sub x 0 !i in
  let y = Array.sub y 0 !i in
  let nodes = (x, y) in

  let edge_len = read_int_2 buf 2 in
  let edges = Array.make edge_len (0, 0, 0, 0, nodes) in
  let i = ref 0 in
  let node = ref 0 in
  while !pos < edge_len + node_len + 4 do
    let n1 = !node + read_signed_varint buf pos in
    node := n1;
    let n2 = !node + read_signed_varint buf pos in
    node := n2;
    let cat = Char.code buf.[!pos] in
    let layer = Char.code buf.[!pos + 1] in
    pos := !pos + 2;
    edges.(!i) <- (n1, n2, cat, layer, nodes);
    incr i
  done;
  Array.sub edges 0 !i

let cache = Lru_cache.make 5000

let decode_leaf = Lru_cache.funct cache (fun i -> build_paths (decode_leaf i))

let find_linear_features x_min y_min x_max y_max =
  let bbox = bounding_box linear_ratio x_min y_min x_max y_max in
  let lst = ref [] in
  Rtree.find linear_rtree bbox (fun i -> lst := decode_leaf i :: !lst);
  Array.concat !lst

(****)

(* R-tree containing surfaces *)

let surface_leaf_size = 2048

let decode_surfaces ratio leaves i =
  let buf = String.create surface_leaf_size in
  seek_in leaves (i * surface_leaf_size);
  really_input leaves buf 0 surface_leaf_size;
  let len = read_int_2 buf 0 in
  let buf =
    if len > 1 then begin
      let buf' = String.create (surface_leaf_size * len) in
      String.blit buf 0 buf' 0 surface_leaf_size;
      really_input leaves buf' surface_leaf_size
        ((len - 1) * surface_leaf_size);
      buf'
    end else
      buf
  in
  let n = read_int_2 buf 2 in
  let pos = ref (4 + 4 * n) in
  let lat = ref 0 in
  let lon = ref 0 in
  let ways = ref [] in
  let category = ref 0 in
  let layer = ref 0 in
  let lst = ref [] in
  for i = 0 to n - 1 do
    let l = read_int_2 buf (4 + 4 * i) in
    let cat = Char.code buf.[4 + 4 * i + 2] in
    let lay = Char.code buf.[4 + 4 * i + 3] - 128 in
    if cat <> 0 then begin
      if !ways <> [] then lst := (!category, !layer, List.rev !ways) :: !lst;
      category := cat;
      layer := lay;
      ways := []
    end;
    let x = Array.make (l + 1) 0. in
    let y = Array.make (l + 1) 0. in
    for j = 0 to l - 1 do
      lat := !lat + read_signed_varint buf pos;
      lon := !lon + read_signed_varint buf pos;
      x.(j) <- float (!lon * ratio);
      y.(j) <- Geometry.lat_to_y (float (!lat * ratio));
    done;
    x.(l) <- x.(0);
    y.(l) <- y.(0);
    ways := (x, y) :: !ways
  done;
  if !ways <> [] then lst := (!category, !layer, List.rev !ways) :: !lst;
  !lst

let prepare_surfaces lst =
  Array.of_list
    (List.map
       (fun (cat, layer, ways) ->
          let area =
            List.fold_left
              (fun a (x, y) -> a +. Geometry.polygon_area_float x y) 0. ways in
          (layer, truncate (area +. 0.5), cat, ways))
       lst)

let decode_surfaces ratio leaves =
  Lru_cache.funct cache
    (fun i -> prepare_surfaces (decode_surfaces ratio leaves i))

let open_tree name =
  let ch = open_in (Column.file_in_database (Filename.concat name "ratio")) in
  let ratio = int_of_string (input_line ch) in
  close_in ch;
  let (leaves, tree) = Rtree.open_in (Column.file_in_database name) in
  let leaves = open_in leaves in
  (ratio, decode_surfaces ratio leaves, tree)

let large_surfaces = open_tree "surfaces/rtrees/large"

let rtrees =
  [((-1., 8.), open_tree "surfaces/rtrees/08");
   ((8., 10.), open_tree "surfaces/rtrees/10");
   ((10., 12.), open_tree "surfaces/rtrees/12");
   ((12., 30.), large_surfaces);
   ((15.5, 30.), open_tree "surfaces/rtrees/small")]

let find_surfaces level x_min y_min x_max y_max =
  let lst = ref [] in
  List.iter
    (fun ((min_level, max_level), (ratio, decode, tree)) ->
       if level > min_level && level <= max_level then begin
         let bbox = bounding_box ratio x_min y_min x_max y_max in
         Rtree.find tree bbox
           (fun i -> lst := decode i :: !lst)
       end)
    rtrees;
  Array.concat !lst

(**** Pixmap ***)

type rectangle = { x : int; y : int; width : int; height: int }

let empty_rectangle = {x = 0; y = 0; width = 0; height = 0}
let rectangle_is_empty r = r.width = 0 || r.height = 0

type surface =
  { mutable surface : Cairo.Surface.t option;
    mutable p_width : int; mutable p_height : int;
    mutable valid_rect : rectangle }

let make_surface () =
  { surface = None; p_width = 0; p_height = 0;
    valid_rect = empty_rectangle }

let invalidate_surface p = p.valid_rect <- empty_rectangle

let grow_surface pm window width height =
  let width = max width pm.p_width in
  let height = max height pm.p_height in
  if width > pm.p_width || height > pm.p_height then begin
    let old_p = pm.surface in
(*
    let p = GDraw.pixmap ~width ~height ~window () in
*)
    let p =
      Cairo.Surface.create_similar
        (Cairo.get_target (Cairo_gtk.create window#misc#window))
        Cairo.COLOR_ALPHA ~width ~height
    in
    let r = pm.valid_rect in
    begin match old_p with
      Some old_p ->
        let ctx = Cairo.create p in
        Cairo.set_source_surface ctx old_p 0. 0.;
        Cairo.rectangle ctx 0. 0. (float r.width) (float r.height);
        Cairo.set_operator ctx Cairo.SOURCE;
        Cairo.fill ctx
(*
        p#put_pixmap ~x:0 ~y:0 ~xsrc:0 ~ysrc:0
          ~width:r.width ~height:r.height old_p#pixmap
*)
    | None ->
        ()
    end;
    pm.surface <- Some p;
    pm.p_width <- width;
    pm.p_height <- height
  end

let get_surface pm = match pm.surface with Some p -> p | None -> assert false

(**** Global state ***)

type state =
  { mutable rect : rectangle;
    mutable level : float;
    mutable prev_rect : rectangle;
    mutable prev_level : float;
    mutable active : bool;
    mutable timeout : Glib.Timeout.id option;
    surface : surface;
    mutable marker1 : (int * float * float) option;
    mutable marker2 : (int * float * float) option;
    mutable path : (int * int) list }

let compute_scale st = 256. /. 360. *. 2. ** st.level

(**** Routing ****)

let find_marker st x y =
  let scale = 256. /. 360. *. 2. ** st.level in
  let x' = (float st.rect.x +. x) /. scale in
  let y' = -. (float st.rect.y +. y) /. scale in
  let lat = truncate (Geometry.y_to_lat (y' *. 10_000_000.)) in
  let lon = truncate ((x' *. 10_000_000.)) in
  Format.eprintf "%d %d@." lat lon;
  let (d, (i, lat, lon)) = nearest_point lat lon in
  let lat = float lat /. 200000. in
  let lon = float lon /. 200000. in
  Format.eprintf "%d: %f - %f %f@." i (float d /. 1000.) lat lon;
  Some (i, lat, lon)

let routing = Routing.init ()
let node_lat = Column.open_in (Column.named "highway/sorted_node" "lat")
let node_lon = Column.open_in (Column.named "highway/sorted_node" "lon")

let update_route st =
  begin match st.marker1, st.marker2 with
    Some (i1, _, _), Some (i2, _, _) ->
      let l = Routing.find routing i1 i2 in
      st.path <-
        List.map (fun n -> (Column.get node_lat n, Column.get node_lon n)) l
  | _ ->
      ()
  end

(****)

let draw_linear_features st ctx pred stroke i =
  let scale = compute_scale st in
  let prev_info = ref (-1, 0, false, false) in
  let count = ref 0 in
  i (fun (info, ways) ->
       if pred info then begin
         if info <> !prev_info then
           if !count > 0 then stroke !prev_info;
         prev_info := info;
         List.iter
           (fun (x, y) ->
              let len = Array.length x in
              if !count > 0 && !count + len > 10000 then begin
                stroke !prev_info;
                count := 0
              end;
              let coeff = scale /. 10_000_000. in
              if st.level >= 15. && Array.length x > 2 then begin
                (*XXX This could be precomputed when decoding the path *)
                let ((x, y), (x1, y1), (x2, y2)) =
                  Line_smoothing.perform x y in
                let len = Array.length x in
                count := !count + 3 * len;
                Cairo.move_to ctx (x.(0) *. coeff) (y.(0) *. coeff);
                for k = 1 to len - 1 do
                  Cairo.curve_to ctx
                    (x1.(k - 1) *. coeff) (y1.(k - 1) *. coeff)
                    (x2.(k - 1) *. coeff) (y2.(k - 1) *. coeff)
                    (x.(k) *. coeff) (y.(k) *. coeff)
                done
              end else begin
                count := !count + len;
                Cairo.move_to ctx (x.(0) *. coeff) (y.(0) *. coeff);
                for k = 1 to len - 1 do
                  Cairo.line_to ctx (x.(k) *. coeff) (y.(k) *. coeff)
                done
              end)
           ways
       end);
  if !count > 0 then stroke !prev_info

let draw_surfaces st ctx pred fill i =
  let scale = compute_scale st in
  let prev_cat = ref (-1) in
  let count = ref 0 in
  i
    (fun ((_, area, cat, ways) as info) ->
       if pred info then begin
         if (cat <> !prev_cat || !count > 10000) && !prev_cat <> -1 then begin
           fill !prev_cat;
           count := 0;
         end;
         let coeff = scale /. 10_000_000. in
         List.iter
           (fun (x, y) ->
              Cairo.move_to ctx (x.(0) *. coeff) (y.(0) *. coeff);
              for i = 1 to Array.length x - 2 do
                Cairo.line_to ctx (x.(i) *. coeff) (y.(i) *. coeff)
              done;
              Cairo.Path.close ctx;
              count := !count + Array.length x)
           ways;
         if cat <> !prev_cat then prev_cat := cat
       end);
  if !prev_cat <> -1 then fill !prev_cat

(****)

let draw_map_high_levels st ctx surfaces linear_features =
  let scale = compute_scale st in
   let module SP = Surface.Partition in
   let partition = SP.make () in
   let landuse =
     SP.add_group partition
       [`Forest; `Grass; `Farmland; `Residential; `Commercial;
        `Industrial; `Park; `Cemetery; `Parking ]
   in
   let water = SP.add_group partition [`Water] in
   let building_or_pedestrian =
     SP.add_group partition
       [`Building;
        `Highway_pedestrian; `Highway_track; `Highway_footway; `Highway_path ]
   in
   let highway_areas =
     SP.add_group partition
       [`Highway_residential; `Highway_unclassified;
        `Highway_living_street; `Highway_service ]
   in
let t = Unix.gettimeofday () in
   let area = Array.map (fun (_, a, _, _) -> - log2 a) surfaces in
   let layer = Array.map (fun (l, _, _, _) -> l) surfaces in
let surfaces' = surfaces in
   let surfaces =
     SP.apply partition surfaces (fun (_, _, cat, _) -> cat)
       >> SP.order_totally
       >> SP.order_by area
       >> SP.order_by layer
       >> SP.order_by_group
       >> SP.select
   in
if debug_time then
Format.eprintf "Sorting surfaces (%d elements): %.3f@." (Array.length surfaces') (Unix.gettimeofday () -. t);

let t = Unix.gettimeofday () in
   let module LP = Linear_feature.Partition in
   let partition = LP.make () in
   let waterway = LP.add_group partition [`Waterway] in
   let ways =
     LP.add_group partition
       [ `Runway; `Taxiway;
         `Rail; `Tram; `Subway;
         `Pedestrian; `Track; `Cycleway; `Bridleway; `Footway; `Path; `Steps;
         `Residential; `Unclassified; `Living_street; `Road; `Service;
         `Tertiary_link; `Secondary_link; `Primary_link;
         `Tertiary; `Secondary; `Primary;
         `Trunk_link; `Motorway_link;
         `Trunk; `Motorway ]
   in
   let layer =
     Array.map
       (fun ((cat, lay, is_bridge, is_tunnel), _) ->
          16 +
          lay * 3 + (if is_bridge then 1 else 0)
                  - (if is_tunnel then 1 else 0))
       linear_features
   in
let linear_features' = linear_features in
   let linear_features =
     LP.apply partition linear_features (fun ((cat, _, _, _), _) -> cat)
       >> LP.order_totally
       >> LP.order_by layer
       >> LP.order_by_group
       >> LP.select
   in
if debug_time then
Format.eprintf "Sorting lines (%d elements): %.3f@." (Array.length linear_features') (Unix.gettimeofday () -. t);
if debug_time then begin
let n = ref 0 in
Array.iter (fun (_, _, _, ways) -> List.iter (fun (x, _) -> n := !n + Array.length x) ways) surfaces';
Format.eprintf "Surfaces: %d nodes@." !n;
   let small_area = truncate (16. *. (*64. *.*) (10_000_000. /. scale) ** 2.) in
   let filter (_, area, cat, ways) =
     st.level >= 15.5 ||
     (area > small_area &&
      (area > 50_000_000 || Surface.of_id cat <> `Building))
   in
let n = ref 0 in
let m = ref 0 in
Array.iter (fun ((_, _, _, ways) as info) -> if filter info then begin incr m; List.iter (fun (x, _) -> n := !n + Array.length x) ways end) surfaces';
Format.eprintf "Surfaces: %d nodes, %d elements (%.2f%%)@." !n !m (100. *. float !m /. float (Array.length surfaces'));
let n = ref 0 in
Array.iter (fun (_, ways) -> List.iter (fun (x, _) -> n := !n + Array.length x) ways) linear_features';
Format.eprintf "Lines: %d nodes@." !n
end;
   let draw_water_lines layer =
     Cairo.set_line_join ctx Cairo.JOIN_ROUND;
     begin match layer with
       `Tunnel ->
         Cairo.set_dash ctx [|2.; 4.|]
     | `Bridge ->
         Cairo.set_line_cap ctx Cairo.BUTT;
         Cairo.set_source_rgb ctx 0. 0. 0.;
         Cairo.set_line_width ctx 4.;
         linear_features >> LP.with_group waterway >> LP.iter
           >> draw_linear_features st ctx
                (fun (_, _, is_bridge, is_tunnel) -> is_bridge)
                (fun _ -> Cairo.stroke ctx)
     | `Ground ->
         ()
     end;
     Cairo.set_line_cap ctx Cairo.ROUND;
     Cairo.set_source_rgb ctx 0.52 0.94 0.94;
     Cairo.set_line_width ctx 2.;
     linear_features >> LP.with_group waterway >> LP.iter
       >> draw_linear_features st ctx
            (fun (_, _, is_bridge, is_tunnel) ->
               match layer with
                 `Tunnel -> is_tunnel
               | `Bridge -> is_bridge
               | `Ground -> not (is_tunnel || is_bridge))
            (fun _ -> Cairo.stroke ctx);
     Cairo.set_dash ctx [||]
   in
   let draw_casing round i =
     Cairo.set_line_cap ctx (if round then Cairo.ROUND else Cairo.BUTT);
     Cairo.set_line_join ctx Cairo.JOIN_ROUND;
     Cairo.set_dash ctx [||];
     let stroke (cat, _,  _, is_tunnel) =
       let cat = Linear_feature.of_id cat in
       begin match cat with
         `Pedestrian | `Track | `Cycleway | `Bridleway | `Footway
       | `Path | `Steps | `Rail | `Tram | `Subway ->
     	   Cairo.set_source_rgb ctx 1. 1. 1.
       | _ ->
           Cairo.set_source_rgb ctx 0. 0. 0.
       end;
       let line_width =
         match cat with
           `Trunk | `Motorway -> 11.
         | `Trunk_link | `Motorway_link -> 6.5
         | `Tertiary | `Secondary | `Primary -> 8.
         | `Tertiary_link | `Secondary_link | `Primary_link -> 5.5
         | `Residential | `Unclassified | `Living_street | `Road -> 6.
         | `Service -> 4.
         | `Pedestrian | `Track | `Cycleway
         | `Bridleway | `Footway | `Path | `Steps -> 4.
         | `Rail -> 5.
         | `Tram | `Subway -> 6.
         | _  -> assert false
       in
       let line_width = if round then line_width else line_width -. 0.5 in
       Cairo.set_line_width ctx line_width;
       Cairo.stroke ctx;
     in
     draw_linear_features st ctx
       (fun (cat, _, is_bridge, _) ->
          match Linear_feature.of_id cat with
            `Motorway | `Trunk | `Primary | `Secondary | `Tertiary
          | `Motorway_link | `Trunk_link | `Primary_link
          | `Secondary_link | `Tertiary_link
          | `Residential | `Unclassified | `Living_street | `Road
          | `Service ->
              true
          | `Pedestrian | `Track | `Cycleway | `Bridleway | `Footway
          | `Path | `Steps | `Rail | `Tram | `Subway when is_bridge ->
              true
          | _ ->
              false)
       stroke i
   in
   let draw_inline i =
     Cairo.set_line_join ctx Cairo.JOIN_ROUND;
     Cairo.set_line_cap ctx Cairo.ROUND;
     let stroke (cat, _, _, is_tunnel) =
       let cat = Linear_feature.of_id cat in
       if cat = `Rail then begin
         Cairo.set_line_cap ctx Cairo.BUTT;
         Cairo.set_dash ctx [|1.; 3.|];
         Cairo.set_source_rgb ctx 0.27 0.27 0.27;
         Cairo.set_line_width ctx 3.;
         Cairo.stroke_preserve ctx;
         Cairo.set_line_cap ctx Cairo.ROUND;
         Cairo.set_dash ctx [||]
       end;
       begin match cat with
         `Motorway | `Trunk | `Motorway_link | `Trunk_link ->
           Cairo.set_source_rgb ctx 1. 0.8 0.
       | `Pedestrian | `Track | `Cycleway | `Bridleway
       | `Footway | `Path | `Steps ->
           Cairo.set_source_rgb ctx 0. 0. 0.;
           Cairo.set_line_cap ctx Cairo.BUTT;
           if cat = `Steps then
             Cairo.set_dash ctx [|1.; 2.|]
           else
             Cairo.set_dash ctx [|2.; 3.|]
       | `Residential | `Unclassified | `Living_street | `Road | `Service ->
           Cairo.set_source_rgb ctx 0.8 0.8 0.8
       | `Rail | `Tram ->
         Cairo.set_source_rgb ctx 0.27 0.27 0.27
       | `Subway ->
           Cairo.set_source_rgb ctx 0.6 0.6 0.6
       | `Runway | `Taxiway ->
           Cairo.set_source_rgb ctx 0.73 0.73 0.8
       | _ ->
           Cairo.set_source_rgb ctx 1. 1. 1.
       end;
       let line_width =
         match cat with
           `Motorway | `Trunk -> 6.
         | `Motorway_link | `Trunk_link -> 3.
         | `Primary | `Secondary | `Tertiary -> 5.
         | `Primary_link | `Secondary_link | `Tertiary_link -> 2.5
         | `Residential | `Unclassified | `Living_street | `Road -> 4.
         | `Service -> 2.5
         | `Rail -> 1.
         | `Tram | `Subway -> 2.
         | `Steps -> 3.
         | `Pedestrian | `Track | `Cycleway
         | `Bridleway | `Footway | `Path -> 1.
         | `Runway -> max (2.5e-4 *. scale) 2.
         | _  -> 2.
       in
       Cairo.set_line_width ctx line_width;
       Cairo.stroke ctx;
       begin match cat with
         `Pedestrian | `Track | `Cycleway | `Bridleway
       | `Footway | `Path | `Steps ->
           Cairo.set_line_cap ctx Cairo.ROUND;
           Cairo.set_dash ctx [||]
       | _ ->
           ()
       end
     in
     draw_linear_features st ctx
       (fun (cat, _, _, is_tunnel) ->
          not is_tunnel || Linear_feature.of_id cat <> `Subway)
       stroke i
   in

let t = Unix.gettimeofday () in
   (* Draw surfaces *)
   let fill_surface cat =
     let cat = Surface.of_id cat in
     begin match cat with
       `Water ->
     	   Cairo.set_source_rgb ctx 0.52 0.94 0.94
     | `Building ->
     	   Cairo.set_source_rgb ctx 0.7 0.7 0.7
     | `Residential ->
     	   Cairo.set_source_rgb ctx 0.91 0.94 0.94
     | `Forest ->
     	   Cairo.set_source_rgb ctx 0.1 0.7 0.2
     | `Grass ->
     	   Cairo.set_source_rgb ctx 0.3 0.9 0.3
     | `Park ->
     	   Cairo.set_source_rgb ctx 0.6 1.0 0.6
     | `Farmland ->
     	   Cairo.set_source_rgb ctx 0.69 0.94 0.27
     | `Cemetery ->
     	   Cairo.set_source_rgb ctx 0.67 0.8 0.69
     | `Commercial ->
     	   Cairo.set_source_rgb ctx 0.94 0.78 0.78
     | `Industrial ->
     	   Cairo.set_source_rgb ctx 0.87 0.82 0.85
     | `Parking ->
     	   Cairo.set_source_rgb ctx 0.97 0.94 0.72
     | `Highway_pedestrian | `Highway_track
     | `Highway_footway | `Highway_path ->
           Cairo.set_source_surface ctx pedestrian_surface 0. 0.;
           Cairo.Pattern.set_extend (Cairo.get_source ctx) Cairo.Pattern.REPEAT
     | `Highway_residential | `Highway_unclassified
     | `Highway_living_street | `Highway_service ->
         Cairo.set_source_rgb ctx 0.8 0.8 0.8
     end;
     if st.level >= 17. && cat = `Building then begin
   	 Cairo.set_source_rgb ctx 0.71 0.71 0.71;
       Cairo.fill_preserve ctx;
     	 Cairo.set_source_rgb ctx 0.6 0.6 0.6;
       Cairo.set_line_width ctx 1.;
       Cairo.stroke ctx
     end else
       Cairo.fill ctx
   in
   let small_area = truncate (32. *. (10_000_000. /. scale) ** 2.) in
   let filter (_, area, cat, ways) =
     st.level >= 15.5 ||
     (area > small_area &&
      (area > 50_000_000 || Surface.of_id cat <> `Building))
   in
   surfaces >> SP.with_group landuse >> SP.iter
     >> draw_surfaces st ctx filter fill_surface;
   (* Draw water lines (below buildings) *)
   draw_water_lines `Ground;
   surfaces >> SP.with_group water >> SP.iter
     >> draw_surfaces st ctx filter fill_surface;
   surfaces >> SP.with_group building_or_pedestrian >> SP.iter
     >> draw_surfaces st ctx filter fill_surface;

if debug_time then
Format.eprintf "Drawing surfaces: %.3f@." (Unix.gettimeofday () -. t);

let t = Unix.gettimeofday () in
   (* Draw linear features *)
   let ways = linear_features >> LP.with_group ways in
   (* Underground features *)
   Cairo.Group.push ctx;
   draw_water_lines `Tunnel;
   ways >> LP.iter_by_key
     (fun layer i -> if layer mod 3 = 0 then draw_casing true (LP.iter i));
   ways >> LP.iter_by_key
     (fun layer i ->
        if layer mod 3 = 0 then begin
          draw_casing false (LP.iter i); draw_inline (LP.iter i)
        end);
   Cairo.Group.pop_to_source ctx;
   Cairo.paint ~alpha:0.4 ctx;
   (* Outline *)
   ways >> LP.iter_by_key
     (fun layer i ->
        if layer mod 3 <> 0 then draw_casing true (LP.iter i));
   (* Casing/inline *)
   surfaces >> SP.with_group highway_areas >> SP.iter
     >> draw_surfaces st ctx filter fill_surface;
   ways >> LP.iter_by_key
     (fun layer i ->
        if layer mod 3 <> 0 then begin
          if layer mod 3 = 2 then draw_casing false (LP.iter i);
          draw_inline (LP.iter i)
        end);
   draw_water_lines `Bridge;
if debug_time then
Format.eprintf "Drawing lines: %.3f@." (Unix.gettimeofday () -. t)

let draw_map_medium_levels st ctx surfaces linear_features =
  let scale = compute_scale st in
   let module SP = Surface.Partition in
   let partition = SP.make () in
   let landuse =
     SP.add_group partition
       [`Forest; `Grass; `Farmland; `Residential; `Commercial;
        `Industrial; `Park; `Cemetery; `Parking ]
   in
   let water = SP.add_group partition [`Water] in
   let building_or_pedestrian =
     SP.add_group partition
       [`Building;
        `Highway_pedestrian; `Highway_track; `Highway_footway; `Highway_path ]
   in
   let highway_areas =
     SP.add_group partition
       [`Highway_residential; `Highway_unclassified;
        `Highway_living_street; `Highway_service ]
   in
let t = Unix.gettimeofday () in
   let area = Array.map (fun (_, a, _, _) -> - log2 a) surfaces in
   let layer = Array.map (fun (l, _, _, _) -> l) surfaces in
let surfaces' = surfaces in
   let surfaces =
     SP.apply partition surfaces (fun (_, _, cat, _) -> cat)
       >> SP.order_totally
       >> SP.order_by area
       >> SP.order_by layer
       >> SP.order_by_group
       >> SP.select
   in
if debug_time then
Format.eprintf "Sorting surfaces (%d elements): %.3f@." (Array.length surfaces') (Unix.gettimeofday () -. t);

let t = Unix.gettimeofday () in
   let module LP = Linear_feature.Partition in
   let partition = LP.make () in
   let waterway = LP.add_group partition [`Waterway] in
   let ignored_ways =
     LP.add_group partition [ `Footway; `Steps; `Service ] in
   let minor_roads =
     LP.add_group partition
       [ `Runway; `Taxiway;
         `Rail; `Tram; `Subway;
         `Pedestrian; `Track; `Cycleway; `Bridleway; `Path;
         `Residential; `Unclassified; `Living_street; `Road ]
   in
   let major_road_links =
     LP.add_group partition
       [ `Tertiary_link; `Secondary_link; `Primary_link ] in
   let major_roads =
     LP.add_group partition [ `Tertiary; `Secondary; `Primary ] in
   let highway_links =
     LP.add_group partition [ `Trunk_link; `Motorway_link ] in
   let highways = LP.add_group partition [ `Trunk; `Motorway ] in
let linear_features' = linear_features in
   let linear_features =
     LP.apply partition linear_features (fun ((cat, _, _, _), _) -> cat)
       >> LP.order_totally
       >> LP.order_by_group
       >> LP.select
   in
if debug_time then
Format.eprintf "Sorting lines (%d elements): %.3f@." (Array.length linear_features') (Unix.gettimeofday () -. t);
if debug_time then begin
let n = ref 0 in
Array.iter (fun (_, _, _, ways) -> List.iter (fun (x, _) -> n := !n + Array.length x) ways) surfaces';
Format.eprintf "Surfaces: %d nodes@." !n;
   let small_area = truncate (32. *. (10_000_000. /. scale) ** 2.) in
   let filter (_, area, cat, ways) =
     (area > small_area &&
      (area > 50_000_000 || Surface.of_id cat <> `Building))
   in
let n = ref 0 in
let m = ref 0 in
Array.iter (fun ((_, _, _, ways) as info) -> if filter info then begin incr m; List.iter (fun (x, _) -> n := !n + Array.length x) ways end) surfaces';
Format.eprintf "Surfaces: %d nodes, %d elements (%.2f%%)@." !n !m (100. *. float !m /. float (Array.length surfaces'));
let n = ref 0 in
Array.iter (fun (_, ways) -> List.iter (fun (x, _) -> n := !n + Array.length x) ways) linear_features';
Format.eprintf "Lines: %d nodes@." !n
end;
   let draw_water_lines () =
     Cairo.set_line_cap ctx Cairo.BUTT;
     Cairo.set_line_join ctx Cairo.JOIN_MITER;
     Cairo.set_miter_limit ctx 1.4;
     Cairo.set_source_rgb ctx 0.52 0.94 0.94;
     Cairo.set_line_width ctx 2.;
     linear_features >> LP.with_group waterway >> LP.iter
       >> draw_linear_features st ctx
            (fun (_, _, is_bridge, is_tunnel) -> not is_tunnel)
            (fun _ -> Cairo.stroke ctx);
     Cairo.set_dash ctx [||]
   in
   let draw_casing i =
     Cairo.set_line_cap ctx Cairo.BUTT;
     Cairo.set_line_join ctx Cairo.JOIN_MITER;
     Cairo.set_miter_limit ctx 1.4;
     Cairo.set_dash ctx [||];
     Cairo.set_source_rgb ctx 0. 0. 0.;
     let stroke (cat, _,  _, is_tunnel) =
       let cat = Linear_feature.of_id cat in
       let line_width =
         match cat with
           `Trunk | `Motorway -> 8.
         | _ -> 5.
       in
       Cairo.set_line_width ctx line_width;
       Cairo.stroke ctx;
     in
     draw_linear_features st ctx
       (fun (cat, _, is_bridge, _) ->
          match Linear_feature.of_id cat with
            `Motorway | `Trunk | `Primary | `Secondary | `Tertiary
          | `Motorway_link | `Trunk_link
          | `Residential | `Unclassified | `Living_street | `Road ->
              true
          | _ ->
              false)
       stroke i
   in
   let draw_inline i =
     Cairo.set_line_cap ctx Cairo.BUTT;
     Cairo.set_line_join ctx Cairo.JOIN_MITER;
     Cairo.set_miter_limit ctx 1.4;
     let stroke (cat, _, _, is_tunnel) =
       let cat = Linear_feature.of_id cat in
       begin match cat with
         `Motorway | `Trunk | `Motorway_link | `Trunk_link ->
           Cairo.set_source_rgb ctx 1. 0.8 0.
       | `Pedestrian | `Track | `Path | `Cycleway | `Bridleway ->
           Cairo.set_source_rgb ctx 0. 0. 0.;
           Cairo.set_line_cap ctx Cairo.BUTT;
           Cairo.set_dash ctx [|2.; 3.|]
       | `Residential | `Unclassified | `Living_street | `Road ->
           Cairo.set_source_rgb ctx 0.7 0.7 0.7
       | `Rail | `Tram ->
         Cairo.set_source_rgb ctx 0.27 0.27 0.27
       | `Subway ->
           Cairo.set_source_rgb ctx 0.6 0.6 0.6
       | `Runway | `Taxiway ->
           Cairo.set_source_rgb ctx 0.73 0.73 0.8
       | _ ->
           Cairo.set_source_rgb ctx 1. 1. 1.
       end;
       let line_width =
         match cat with
           `Motorway | `Trunk -> 4.
         | `Motorway_link | `Trunk_link -> 1.
         | `Primary | `Secondary | `Tertiary -> 3.
         | `Primary_link | `Secondary_link | `Tertiary_link -> 3. (*???*)
         | `Residential | `Unclassified | `Living_street | `Road ->
              1.5
         | `Rail -> 1.
         | `Tram | `Subway -> 2.
         | `Pedestrian | `Track | `Cycleway | `Path | `Bridleway -> 1.
         | `Runway -> max (2.5e-4 *. scale) 2.
         | _  -> 1.
       in
       Cairo.set_line_width ctx line_width;
       Cairo.stroke ctx;
       begin match cat with
         `Pedestrian | `Track | `Path | `Cycleway | `Bridleway ->
           Cairo.set_dash ctx [||]
       | _ ->
           ()
       end
     in
     draw_linear_features st ctx
       (fun (cat, _, _, is_tunnel) ->
          not is_tunnel || Linear_feature.of_id cat <> `Subway)
       stroke i
   in

let t = Unix.gettimeofday () in
   (* Draw surfaces *)
   let fill_surface cat =
     let cat = Surface.of_id cat in
     begin match cat with
       `Water ->
     	   Cairo.set_source_rgb ctx 0.52 0.94 0.94
     | `Building ->
     	   Cairo.set_source_rgb ctx 0.6 0.6 0.6
     | `Residential ->
     	   Cairo.set_source_rgb ctx 0.91 0.94 0.94
     | `Forest ->
     	   Cairo.set_source_rgb ctx 0.1 0.7 0.2
     | `Grass ->
     	   Cairo.set_source_rgb ctx 0.3 0.9 0.3
     | `Park ->
     	   Cairo.set_source_rgb ctx 0.6 1.0 0.6
     | `Farmland ->
     	   Cairo.set_source_rgb ctx 0.69 0.94 0.27
     | `Cemetery ->
     	   Cairo.set_source_rgb ctx 0.67 0.8 0.69
     | `Commercial ->
     	   Cairo.set_source_rgb ctx 0.94 0.78 0.78
     | `Industrial ->
     	   Cairo.set_source_rgb ctx 0.87 0.82 0.85
     | `Parking ->
     	   Cairo.set_source_rgb ctx 0.97 0.94 0.72
     | `Highway_pedestrian | `Highway_track
     | `Highway_footway | `Highway_path ->
           Cairo.set_source_surface ctx pedestrian_surface 0. 0.;
           Cairo.Pattern.set_extend (Cairo.get_source ctx) Cairo.Pattern.REPEAT
     | `Highway_residential | `Highway_unclassified
     | `Highway_living_street | `Highway_service ->
         Cairo.set_source_rgb ctx 0.8 0.8 0.8
     end;
     Cairo.fill ctx
   in
   let small_area = truncate ((*64.*)16. *. (10_000_000. /. scale) ** 2.) in
   let filter (_, area, cat, ways) =
     (area > small_area &&
      (area > 50_000_000 || Surface.of_id cat <> `Building))
   in
   surfaces >> SP.with_group landuse >> SP.iter
     >> draw_surfaces st ctx filter fill_surface;
   (* Draw water lines (below buildings) *)
   draw_water_lines ();
   surfaces >> SP.with_group water >> SP.iter
     >> draw_surfaces st ctx filter fill_surface;
   surfaces >> SP.with_group building_or_pedestrian >> SP.iter
     >> draw_surfaces st ctx filter fill_surface;

if debug_time then
Format.eprintf "Drawing surfaces: %.3f@." (Unix.gettimeofday () -. t);

let t = Unix.gettimeofday () in
   (* Draw linear features *)
   let l =
     [minor_roads; major_road_links; major_roads; highway_links; highways] in
   List.iter
     (fun g ->
        if g <> minor_roads then
          linear_features >> LP.with_group g >> LP.iter >> draw_casing;
        linear_features >> LP.with_group g >> LP.iter >> draw_inline)
     l;
if debug_time then
Format.eprintf "Drawing lines: %.3f@." (Unix.gettimeofday () -. t)

let partition_high =
  ([ `Footway; `Steps; `Service;
     `Tram; `Subway; `Taxiway;
     `Pedestrian; `Track; `Cycleway; `Bridleway; `Path;
     `Residential; `Unclassified; `Living_street; `Road ],
   [ `Runway; `Rail; `Tertiary_link; `Tertiary ],
   [ `Primary_link; `Primary; `Secondary_link; `Secondary ],
   [ `Trunk_link; `Motorway_link; `Trunk; `Motorway ])

let partition_medium =
  ([ `Footway; `Steps; `Service;
     `Tram; `Subway; `Taxiway; `Runway;
     `Pedestrian; `Track; `Cycleway; `Bridleway; `Path;
     `Residential; `Unclassified; `Living_street; `Road;
     `Tertiary_link; `Tertiary ],
   [ `Rail; `Secondary_link; `Secondary ],
   [ `Primary_link; `Primary ],
   [ `Trunk_link; `Motorway_link; `Trunk; `Motorway ])

let partition_low =
  ([ `Footway; `Steps; `Service;
     `Tram; `Subway; `Taxiway; `Runway;
     `Pedestrian; `Track; `Cycleway; `Bridleway; `Path;
     `Residential; `Unclassified; `Living_street; `Road;
     `Tertiary_link; `Tertiary; `Secondary_link; `Secondary ],
   [ `Rail ],
   [ `Primary_link; `Primary ],
   [ `Trunk_link; `Motorway_link; `Trunk; `Motorway ])

let draw_map_intermediate_levels
      st ctx road_partition surfaces linear_features =
  let scale = compute_scale st in
   let module SP = Surface.Partition in
   let partition = SP.make () in
   let landuse =
     SP.add_group partition
       [`Forest; `Grass; `Farmland; `Residential; `Commercial;
        `Industrial; `Park; `Cemetery; `Parking ]
   in
   let water = SP.add_group partition [`Water] in
   let building_or_pedestrian =
     SP.add_group partition
       [`Building;
        `Highway_pedestrian; `Highway_track; `Highway_footway; `Highway_path ]
   in
   let highway_areas =
     SP.add_group partition
       [`Highway_residential; `Highway_unclassified;
        `Highway_living_street; `Highway_service ]
   in
let t = Unix.gettimeofday () in
   let area = Array.map (fun (_, a, _, _) -> - log2 a) surfaces in
   let layer = Array.map (fun (l, _, _, _) -> l) surfaces in
let surfaces' = surfaces in
   let surfaces =
     SP.apply partition surfaces (fun (_, _, cat, _) -> cat)
       >> SP.order_totally
       >> SP.order_by area
       >> SP.order_by layer
       >> SP.order_by_group
       >> SP.select
   in
if debug_time then
Format.eprintf "Sorting surfaces (%d elements): %.3f@." (Array.length surfaces') (Unix.gettimeofday () -. t);

let t = Unix.gettimeofday () in
   let module LP = Linear_feature.Partition in
   let partition = LP.make () in
   let waterway = LP.add_group partition [`Waterway] in
   let (ignored_way_cats, minor_road_cats, major_road_cats, highway_cats) =
     road_partition in
   let ignored_ways = LP.add_group partition ignored_way_cats in
   let minor_roads = LP.add_group partition minor_road_cats in
   let major_roads = LP.add_group partition major_road_cats in
   let highways = LP.add_group partition highway_cats in
(*
let linear_features =
  let eps = (10_000_000. /. scale) in
  Array.map
    (fun (((cat, _, _, _) as info, ways) as item) ->
       if List.memq (Linear_feature.of_id cat) ignored_way_cats then
         item
       else
         (info, List.filter (fun (x, y) -> Array.length x > 0) (List.map (fun (x, y) -> Douglas_peucker.perform eps x y) ways)))
    linear_features
in
*)
let linear_features' = linear_features in
   let linear_features =
     LP.apply partition linear_features (fun ((cat, _, _, _), _) -> cat)
       >> LP.order_totally
       >> LP.order_by_group
       >> LP.select
   in
if debug_time then
Format.eprintf "Sorting lines (%d elements): %.3f@." (Array.length linear_features') (Unix.gettimeofday () -. t);
if debug_time then begin
let n = ref 0 in
Array.iter (fun (_, _, _, ways) -> List.iter (fun (x, _) -> n := !n + Array.length x) ways) surfaces';
Format.eprintf "Surfaces: %d nodes@." !n;
   let small_area = truncate (16. *. (*64. *.*) (10_000_000. /. scale) ** 2.) in
   let filter (_, area, cat, ways) =
     (area > small_area &&
      (area > 50_000_000 || Surface.of_id cat <> `Building))
   in
let n = ref 0 in
let m = ref 0 in
Array.iter (fun ((_, _, _, ways) as info) -> if filter info then begin incr m; List.iter (fun (x, _) -> n := !n + Array.length x) ways end) surfaces';
Format.eprintf "Surfaces: %d nodes, %d elements (%.2f%%)@." !n !m (100. *. float !m /. float (Array.length surfaces'));
let n = ref 0 in
Array.iter (fun (_, ways) -> List.iter (fun (x, _) -> n := !n + Array.length x) ways) linear_features';
Format.eprintf "Lines: %d nodes@." !n;
let n = ref 0 in
let n' = ref 0 in
let m = ref 0 in
Array.iter (fun ((cat, _, _, _), ways) -> if not (List.memq (Linear_feature.of_id cat) ignored_way_cats) then begin incr m; List.iter (fun (x, y) -> n := !n + Array.length x; let eps = (10_000_000. /. scale) in let (x', y') = Douglas_peucker.perform eps x y in n' := !n' + Array.length x') ways end) linear_features';
Format.eprintf "Lines: %d nodes (%d), %d elements (%.2f%%)@." !n !n' !m (100. *. float !m /. float (Array.length linear_features'));
end;

   let draw_water_lines () =
     Cairo.set_line_cap ctx Cairo.BUTT;
     Cairo.set_line_join ctx Cairo.JOIN_MITER;
     Cairo.set_miter_limit ctx 1.4;
     Cairo.set_source_rgb ctx 0.52 0.94 0.94;
     Cairo.set_line_width ctx 2.;
     linear_features >> LP.with_group waterway >> LP.iter
       >> draw_linear_features st ctx
            (fun (_, _, is_bridge, is_tunnel) -> not is_tunnel)
            (fun _ -> Cairo.stroke ctx);
     Cairo.set_dash ctx [||]
   in
   let emph_secondary = List.mem `Secondary major_road_cats in
   let draw_casing i =
     Cairo.set_line_cap ctx Cairo.BUTT;
     Cairo.set_line_join ctx Cairo.JOIN_MITER;
     Cairo.set_miter_limit ctx 1.4;
     Cairo.set_dash ctx [||];
     let stroke (cat, _,  _, is_tunnel) =
       let cat = Linear_feature.of_id cat in
       Cairo.set_source_rgb ctx 0. 0. 0.;
       let line_width =
         match cat with
           `Trunk | `Motorway -> 8.
         | `Trunk_link | `Motorway_link -> 5.
         | `Primary -> 5.
         | `Primary_link -> 4.
         | `Secondary | `Secondary_link -> 3.5
         | _  -> assert false
       in
       Cairo.set_line_width ctx line_width;
       Cairo.stroke ctx;
     in
     draw_linear_features st ctx
       (fun (cat, _, is_bridge, _) ->
          let cat = Linear_feature.of_id cat in
          match cat with
            `Motorway | `Trunk | `Primary | `Secondary
          | `Motorway_link | `Trunk_link | `Primary_link | `Secondary_link ->
              true
          | `Secondary | `Secondary_link ->
              emph_secondary
          | _ ->
              false)
       stroke i
   in
   let draw_inline i =
     Cairo.set_line_cap ctx Cairo.BUTT;
     Cairo.set_line_join ctx Cairo.JOIN_MITER;
     Cairo.set_miter_limit ctx 1.4;
     let stroke (cat, _, _, is_tunnel) =
       let cat = Linear_feature.of_id cat in
       begin match cat with
         `Motorway | `Trunk | `Motorway_link | `Trunk_link ->
           Cairo.set_source_rgb ctx 1. 0.8 0.
       | `Tertiary | `Tertiary_link ->
           Cairo.set_source_rgb ctx 0.7 0.7 0.7
       | `Secondary | `Secondary_link when not emph_secondary ->
           Cairo.set_source_rgb ctx 0.7 0.7 0.7
       | `Rail ->
           Cairo.set_source_rgb ctx 0.27 0.27 0.27
       | `Runway ->
           Cairo.set_source_rgb ctx 0.73 0.73 0.8
       | _ ->
           Cairo.set_source_rgb ctx 1. 1. 1.
       end;
       let line_width =
         match cat with
           `Motorway | `Trunk -> 4.
         | `Motorway_link | `Trunk_link -> 1.
         | `Primary -> 3.
         | `Primary_link  -> 2.
         | `Rail -> 1.
         | `Secondary -> 1.5
         | `Secondary_link | `Tertiary_link | `Secondary | `Tertiary -> 1.5
         | `Runway -> max (2.5e-4 *. scale) 1.
         | `Taxiway -> 1.
         | _  -> assert false
       in
       Cairo.set_line_width ctx line_width;
       Cairo.stroke ctx
     in
     draw_linear_features st ctx
       (fun (cat, _, _, is_tunnel) -> true)
       stroke i
   in

let t = Unix.gettimeofday () in
   (* Draw surfaces *)
   let fill_surface cat =
     let cat = Surface.of_id cat in
     begin match cat with
       `Water ->
     	   Cairo.set_source_rgb ctx 0.52 0.94 0.94
     | `Building ->
     	   Cairo.set_source_rgb ctx 0.6 0.6 0.6
     | `Residential ->
     	   Cairo.set_source_rgb ctx 0.91 0.94 0.94
     | `Forest ->
     	   Cairo.set_source_rgb ctx 0.1 0.7 0.2
     | `Grass ->
     	   Cairo.set_source_rgb ctx 0.3 0.9 0.3
     | `Park ->
     	   Cairo.set_source_rgb ctx 0.6 1.0 0.6
     | `Farmland ->
     	   Cairo.set_source_rgb ctx 0.69 0.94 0.27
     | `Cemetery ->
     	   Cairo.set_source_rgb ctx 0.67 0.8 0.69
     | `Commercial ->
     	   Cairo.set_source_rgb ctx 0.94 0.78 0.78
     | `Industrial ->
     	   Cairo.set_source_rgb ctx 0.87 0.82 0.85
     | `Parking ->
     	   Cairo.set_source_rgb ctx 0.97 0.94 0.72
     | `Highway_pedestrian | `Highway_track
     | `Highway_footway | `Highway_path ->
           Cairo.set_source_surface ctx pedestrian_surface 0. 0.;
           Cairo.Pattern.set_extend (Cairo.get_source ctx) Cairo.Pattern.REPEAT
     | `Highway_residential | `Highway_unclassified
     | `Highway_living_street | `Highway_service ->
         Cairo.set_source_rgb ctx 0.8 0.8 0.8
     end;
     Cairo.fill ctx
   in
   let small_area = truncate ((*64.*)16. *. (10_000_000. /. scale) ** 2.) in
   let filter (_, area, cat, ways) =
     (area > small_area &&
      (area > 50_000_000 || Surface.of_id cat <> `Building))
   in
   surfaces >> SP.with_group landuse >> SP.iter
     >> draw_surfaces st ctx filter fill_surface;
   (* Draw water lines (below buildings) *)
   draw_water_lines ();
   surfaces >> SP.with_group water >> SP.iter
     >> draw_surfaces st ctx filter fill_surface;
   surfaces >> SP.with_group building_or_pedestrian >> SP.iter
     >> draw_surfaces st ctx filter fill_surface;

if debug_time then
Format.eprintf "Drawing surfaces: %.3f@." (Unix.gettimeofday () -. t);

let t = Unix.gettimeofday () in
   (* Draw linear features *)
   let l = [minor_roads; major_roads; highways] in
   List.iter
     (fun g ->
        if g <> minor_roads then
          linear_features >> LP.with_group g >> LP.iter >> draw_casing;
        linear_features >> LP.with_group g >> LP.iter >> draw_inline)
     l;
if debug_time then
Format.eprintf "Drawing lines: %.3f@." (Unix.gettimeofday () -. t)

(****)

let draw_map st pm x y width height =
(*
Format.eprintf "map: %d %d %d %d@." x y width height;
*)
  let ctx = Cairo.create pm in

  (* Background *)
  Cairo.rectangle ctx (float x) (float y) (float width) (float height);
  Cairo.clip_preserve ctx;
  Cairo.set_source_rgb ctx 1. 1. 1.;
  Cairo.fill ctx;

  let x = st.rect.x + x in
  let y = st.rect.y + y in

  Cairo.scale ctx 1. (-1.);
  Cairo.translate ctx (-. float st.rect.x) (float st.rect.y);

  let extra = 7 in

  let scale = compute_scale st in
  let lon_min = float (x - extra) /. scale in
  let lon_max = float (x + width + extra) /. scale in
  let lat_min = -. float (y + height + extra) /. scale in
  let lat_max = -. float (y - extra) /. scale in

   (* Load surfaces *)
let t = Unix.gettimeofday () in
  let surfaces = find_surfaces st.level lon_min lat_min lon_max lat_max in
if debug_time then
Format.eprintf "Loading surfaces: %.3f@." (Unix.gettimeofday () -. t);

   (* Load linear features *)
let t = Unix.gettimeofday () in
  let linear_features =
    find_linear_features lon_min lat_min lon_max lat_max in
if debug_time then
Format.eprintf "Loading lines: %.3f@." (Unix.gettimeofday () -. t);
  if st.level >= 14.5 then
    draw_map_high_levels st ctx surfaces linear_features
  else if st.level >= 13.5 then
    draw_map_medium_levels st ctx surfaces linear_features
  else if st.level >= 12.5 then
    draw_map_intermediate_levels
      st ctx partition_high surfaces linear_features
  else if st.level >= 11.5 then
    draw_map_intermediate_levels
      st ctx partition_medium surfaces linear_features
  else
    draw_map_intermediate_levels
      st ctx partition_low surfaces linear_features

(****)

let draw_route st ctx =
   let scale = compute_scale st in
   Cairo.scale ctx 1. (-1.);
   Cairo.translate ctx (-. float st.rect.x) (float st.rect.y);
   let path =
     List.map
       (fun (lat, lon) ->
          let approx x =
            float ((x + linear_ratio / 2 - 1) / linear_ratio * linear_ratio)
          in
          (approx lon /. 10_000_000.,
           Geometry.lat_to_y (approx lat) /. 10_000_000.))
       st.path
   in
   begin match path with
     [] ->
       ()
   | (x, y) :: rem ->
       Cairo.move_to ctx (x *. scale) (y *. scale);
       List.iter
         (fun (x, y) -> Cairo.line_to ctx (x *. scale) (y *. scale))
         rem;
       Cairo.set_line_width ctx 2.;
       Cairo.set_source_rgb ctx 0. 0. 1.;
       Cairo.stroke ctx
   end;

   begin match st.marker1 with
     Some (_, lat, lon) ->
       let x = lon in
       let y = Geometry.lat_to_y (lat *. 10_000_000.) /. 10_000_000. in
       Cairo.arc ctx (x *. scale) (y *. scale) 4. 0. (2. *. Geometry.pi);
       Cairo.set_source_rgb ctx 1. 0. 0.;
       Cairo.fill ctx
   | None ->
       ()
   end;
   begin match st.marker2 with
     Some (_, lat, lon) ->
       let x = lon in
       let y = Geometry.lat_to_y (lat *. 10_000_000.) /. 10_000_000. in
       Cairo.arc ctx (x *. scale) (y *. scale) 4. 0. (2. *. Geometry.pi);
       Cairo.set_source_rgb ctx 0. 0.6 0.;
       Cairo.fill ctx
   | None ->
       ()
   end

let _ =
let width = 512 in
let height = 512 in

let st =
  { rect = { x = 0; y = 0; width = width; height = height };
    prev_rect = { x = 0; y = 0; width = width; height = height };
    level = 17.; prev_level = 17.; active = true; timeout = None;
    surface = make_surface ();
    marker1 = None; marker2 = None; path = [] } in

let lat = ref 48.850 in
let lon =  ref 2.350 in
begin
  let (ratio, _, tree) = large_surfaces in
  let bbox = Rtree.bounding_box tree in
  let c x = truncate (x *. 10_000_000. /. float ratio +. 0.5) in
  Format.eprintf "%a %d %d@." Bbox.print bbox (c !lat) (c !lon);
  if not (Bbox.contains_point bbox (c !lat) (c !lon)) then begin
    let c x = float x /. 10_000_000. *. float ratio in
    lat := c ((bbox.Bbox.min_lat + bbox.Bbox.max_lat) / 2);
    lon := c ((bbox.Bbox.min_lon + bbox.Bbox.max_lon) / 2)
  end
end;
let scale = compute_scale st in
st.rect <-
  { st.rect with
    x = truncate (!lon *. scale) - width / 2;
    y = - truncate (Geometry.lat_to_y (!lat *. 10_000_000.) /. 10_000_000. *. scale) - height / 2 };
Format.eprintf "%d %d@." st.rect.x st.rect.y;

ignore (GMain.Main.init ());
let w = GWindow.window () in
ignore (w#connect#destroy GMain.quit);
let b = GPack.hbox ~packing:w#add () in
let table =
 GPack.table ~width ~height ~columns:1 ~rows:1 ~packing:(b#pack ~expand:true) () in
let display =
  GMisc.drawing_area
    ~packing:(table#attach ~left:0 ~top:0 ~fill:`BOTH ~expand:`BOTH) () in
display#misc#set_can_focus true;
display#misc#set_double_buffered false;

let queue_draw () = GtkBase.Widget.queue_draw display#as_widget in
let refresh () =
  invalidate_surface st.surface;
  queue_draw ()
in

let update_size () =
  let a = display#misc#allocation in
  st.rect <-
    { x = st.rect.x + (st.rect.width - a.Gtk.width) / 2;
      y = st.rect.y + (st.rect.height - a.Gtk.height) / 2;
      width = a.Gtk.width;
      height = a.Gtk.height }
in
(*
ignore (display#event#connect#configure
  (fun ev -> false));
ignore (display#event#connect#map
  (fun ev -> false));
  display#event#add [`STRUCTURE];
*)
ignore (display#event#connect#expose
  (fun ev ->
     let area = GdkEvent.Expose.area ev in
     let x = Gdk.Rectangle.x area in
     let y = Gdk.Rectangle.y area in
     let width = Gdk.Rectangle.width area in
     let height = Gdk.Rectangle.height area in
(*
     Format.eprintf "EXPOSE %d %d %d %d@." x y width height;
*)

     update_size ();
     let a = st.rect in

     let ctx = Cairo_gtk.create (display#misc#window) in
     let pm = st.surface in
     if st.active then begin
       grow_surface st.surface display a.width a.height;

       let dx = pm.valid_rect.x - st.rect.x in
       let dy = pm.valid_rect.y - st.rect.y in

       let p = get_surface pm in
       if
         (dx > 0 && pm.valid_rect.width + dx < a.width) ||
           (dy > 0 && pm.valid_rect.height + dy < a.height)
       then begin
         (* We would have to redraw four rectangles *)
         pm.valid_rect <- empty_rectangle
       end else if not (rectangle_is_empty pm.valid_rect) then begin
         let r = pm.valid_rect in
         if (dx <> 0 || dy <> 0) then begin
           let ctx = Cairo.create p in
           Cairo.set_source_surface ctx p (float dx) (float dy);
           Cairo.rectangle ctx
             (float dx) (float dy) (float r.width) (float r.height);
           Cairo.set_operator ctx Cairo.SOURCE;
           Cairo.fill ctx
         end;
         let offset p l d m = (* 0 <= p; 0 <= l; p + l <= m *)
           if p + d + l <= 0 then
             (0, 0)
           else if p + d < 0 then
             (0, l + p + d)
           else if p + d >= m then
             (m, 0)
           else if p + d + l > m then
             (p + d, m - p - d)
           else
             (p + d, l)
         in
         let (x, width) = offset 0 r.width dx pm.p_width in
         let (y, height) = offset 0 r.height dy pm.p_height in
         if height > 0 then begin
           if x > 0 then begin
             assert (x + width >= a.width);
             draw_map st p 0 y x height
           end else begin
             assert (x = 0);
             if a.width > width then
               draw_map st p width y (a.width - width) height
           end
         end;
         if y > 0 then begin
           assert (y + height >= a.height);
           draw_map st p 0 0 a.width y;
         end else begin
           assert (y = 0);
           if a.height > height then
             draw_map st p 0 height a.width (a.height - height)
         end;
         pm.valid_rect <- st.rect
       end;
       let r = pm.valid_rect in
       if x + width > r.width || y + height > r.height then begin
         draw_map st p 0 0 a.width a.height;
         pm.valid_rect <- st.rect
       end;
       Cairo.set_source_surface ctx p 0. 0.;
     end else begin
       Cairo.set_source_rgb ctx 0.8 0.8 0.8;
       Cairo.rectangle ctx (float x) (float y) (float width) (float height);
       Cairo.fill ctx;
       let p = get_surface pm in
       Cairo.set_source_surface ctx p 0. 0.;
       let coeff = 2. ** (st.prev_level -. st.level) in
       let matrix = Cairo.Matrix.init_identity () in
       Cairo.Matrix.translate matrix
         (-. float st.prev_rect.x) (-. float st.prev_rect.y);
       Cairo.Matrix.scale matrix coeff coeff;
       Cairo.Matrix.translate matrix (float st.rect.x) (float st.rect.y);
       Cairo.Pattern.set_matrix (Cairo.get_source ctx) matrix;
     end;
     Cairo.rectangle ctx (float x) (float y) (float width) (float height);
     Cairo.save ctx;
     (* Workaround for a Cairo bug (in ATI Catalyst drivers?): *)
     if st.active then Cairo.set_operator ctx Cairo.SOURCE;
     Cairo.fill_preserve ctx; 
     Cairo.restore ctx;
     Cairo.clip ctx;
     draw_route st ctx;
     true));

let pos = ref None in
ignore (display#event#connect#button_press
  (fun ev ->
     display#misc#grab_focus ();
     if !pos = None then
       pos := Some (GdkEvent.Button.x ev, GdkEvent.Button.y ev,
                    GdkEvent.Button.button ev, false);
     false));
ignore (display#event#connect#button_release
  (fun ev ->
     let but' = GdkEvent.Button.button ev in
     begin match !pos with
       Some (x, y, but, move) when but = but' ->
         update_size ();
         if not move && but = 1 then begin
           st.marker1 <- find_marker st x y;
           update_route st;
           queue_draw ()
         end else if not move && but = 3 then begin
           st.marker2 <- find_marker st x y;
           update_route st;
           queue_draw ()
         end;
         pos := None
       | _ ->
         ()
     end;
     false));
ignore (display#event#connect#motion_notify
  (fun ev ->
(*Format.eprintf "MOVE@.";*)
     let (x', y') =
       if GdkEvent.Motion.is_hint ev then
         let (x', y') = display#misc#pointer in
         (float x', float y')
       else
         (GdkEvent.Motion.x ev, GdkEvent.Motion.y ev)
     in
     begin match !pos with
       Some (x, y, but, move)
         when but = 1
           && (move || abs_float (x -. x') > 3. || abs_float (y -. y') > 3.) ->
	 st.rect <-
           {st.rect with
            x = st.rect.x + truncate (x -. x');
	    y = st.rect.y + truncate (y -. y') };
         pos := Some (x', y', 1, true);
         queue_draw ()
     | _ ->
         ()
     end;
     false));
display#event#add
  [`BUTTON_PRESS; `BUTTON_RELEASE; `BUTTON1_MOTION; `POINTER_MOTION_HINT];

let perform_zoom ev delta =
  let x = truncate (GdkEvent.Scroll.x ev) in
  let y = truncate (GdkEvent.Scroll.y ev) in
  if (async_zoom || (delta > 0. && async_zoom_in)) && st.active then begin
    st.prev_level <- st.level;
    st.prev_rect <- st.rect;
    st.active <- false
  end;
  st.level <- st.level +. delta;
Format.eprintf "level: %f@." st.level;
  update_size ();
  st.rect <-
    { st.rect with
      x = truncate ((float (st.rect.x + x)) *. 2. ** delta) - x;
      y = truncate ((float (st.rect.y + y)) *. 2. ** delta) - y };
  begin match st.timeout with
    Some id -> Glib.Timeout.remove id
  | None    -> ()
  end;
  if not st.active then
    st.timeout <-
      Some (Glib.Timeout.add async_delay
              (fun () ->
                 st.timeout<- None; st.active <- true; refresh (); false));
  refresh ();
in
ignore (display#event#connect#scroll
          (fun ev ->
             match GdkEvent.Scroll.direction ev with
               `UP ->
                 perform_zoom ev 0.125;
                 true
             | `DOWN ->
                 perform_zoom ev (-0.125);
                 true
             | _ ->
                 false));
display#event#add [`SCROLL];

w#show ();
GMain.main ()
