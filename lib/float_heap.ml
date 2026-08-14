type order = Min | Max

type t = {
  order : order;
  mutable data : float array;
  mutable size : int;
}

let create order = { order; data = Array.make 16 0.; size = 0 }
let length heap = heap.size

let precedes heap left right =
  match heap.order with
  | Min -> Float.compare left right < 0
  | Max -> Float.compare left right > 0

let swap data left right =
  let value = data.(left) in
  data.(left) <- data.(right);
  data.(right) <- value

let grow heap =
  let old_capacity = Array.length heap.data in
  if old_capacity >= Sys.max_array_length then raise Out_of_memory;
  let new_capacity =
    if old_capacity > Sys.max_array_length / 2 then Sys.max_array_length
    else old_capacity * 2
  in
  let data = Array.make new_capacity 0. in
  Array.blit heap.data 0 data 0 heap.size;
  heap.data <- data

let add heap value =
  if heap.size = Array.length heap.data then grow heap;
  let index = ref heap.size in
  heap.data.(!index) <- value;
  heap.size <- heap.size + 1;
  while !index > 0 do
    let parent = (!index - 1) / 2 in
    if precedes heap heap.data.(!index) heap.data.(parent) then (
      swap heap.data !index parent;
      index := parent)
    else index := 0
  done

let peek heap = if heap.size = 0 then None else Some heap.data.(0)

let take heap =
  if heap.size = 0 then None
  else
    let root = heap.data.(0) in
    heap.size <- heap.size - 1;
    if heap.size > 0 then (
      heap.data.(0) <- heap.data.(heap.size);
      let index = ref 0 in
      let searching = ref true in
      while !searching do
        let left = (2 * !index) + 1 in
        if left >= heap.size then searching := false
        else
          let right = left + 1 in
          let child =
            if right < heap.size
               && precedes heap heap.data.(right) heap.data.(left)
            then right
            else left
          in
          if precedes heap heap.data.(child) heap.data.(!index) then (
            swap heap.data child !index;
            index := child)
          else searching := false
      done);
    Some root
