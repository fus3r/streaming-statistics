type create_error = [ `Invalid_capacity of int ]
type add_error = [ `Count_overflow ]

type 'a t = {
  capacity : int;
  slots : 'a option array;
  random : Random.State.t;
  mutable count : int64;
  mutable size : int;
}

let create ~capacity ~seed =
  if capacity <= 0 then Error (`Invalid_capacity capacity)
  else
    Ok
      {
        capacity;
        slots = Array.make capacity None;
        random = Random.State.make [| seed |];
        count = 0L;
        size = 0;
      }

let capacity state = state.capacity
let count state = state.count

let add state value =
  if Int64.equal state.count Int64.max_int then Error `Count_overflow
  else (
    let next_count = Int64.succ state.count in
    (if state.size < state.capacity then (
       state.slots.(state.size) <- Some value;
       state.size <- state.size + 1)
     else
       let index = Random.State.int64 state.random next_count in
       if Int64.compare index (Int64.of_int state.capacity) < 0 then
         state.slots.(Int64.to_int index) <- Some value);
    state.count <- next_count;
    Ok ())

let sample state =
  Array.init state.size (fun index ->
      match state.slots.(index) with Some value -> value | None -> assert false)
