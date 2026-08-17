type level = { mutable data : float array; mutable length : int }

type t = {
  capacity : int;
  random : Random.State.t;
  mutable count : int64;
  mutable levels : level array;
}

type add_error = [ `Non_finite | `Count_overflow ]

let minimum_level_capacity = 8

let is_finite value =
  match classify_float value with
  | FP_normal | FP_subnormal | FP_zero -> true
  | FP_infinite | FP_nan -> false

let make_level storage =
  { data = Array.make (Int.max 1 storage) 0.0; length = 0 }

let create ~capacity ~seed () =
  if capacity < minimum_level_capacity then
    invalid_arg "Kll.create: capacity must be at least 8";
  if capacity >= Sys.max_array_length then
    invalid_arg "Kll.create: capacity is too large for an OCaml array";
  {
    capacity;
    random = Random.State.make [| seed |];
    count = 0L;
    levels = [| make_level (capacity + 1) |];
  }

let capacity state = state.capacity
let count state = state.count

let retained state =
  Array.fold_left (fun total level -> total + level.length) 0 state.levels

(* [ceil (2 * value / 3)] without evaluating the potentially overflowing
   product [2 * value]. *)
let shrink_capacity value =
  let quotient = value / 3 in
  let remainder = value mod 3 in
  (2 * quotient)
  + if remainder = 0 then 0 else if remainder = 1 then 1 else 2

let rec shrink_n value depth =
  if depth = 0 || value <= minimum_level_capacity then value
  else shrink_n (shrink_capacity value) (depth - 1)

let level_capacity state index =
  let depth = Array.length state.levels - index - 1 in
  Int.max minimum_level_capacity (shrink_n state.capacity depth)

let ensure_storage level needed =
  if needed > Array.length level.data then (
    let current = Array.length level.data in
    let doubled =
      if current > Sys.max_array_length / 2 then Sys.max_array_length
      else 2 * current
    in
    let next = Int.max needed doubled in
    if next > Sys.max_array_length then
      invalid_arg "Kll: retained storage exceeds the OCaml array limit";
    let data = Array.make next 0.0 in
    Array.blit level.data 0 data 0 level.length;
    level.data <- data)

let push level value =
  ensure_storage level (level.length + 1);
  level.data.(level.length) <- value;
  level.length <- level.length + 1

let append_top_level state =
  if Array.length state.levels >= 63 then
    invalid_arg "Kll: weighted level would overflow Int64.t";
  state.levels <-
    Array.append state.levels [| make_level (state.capacity + 1) |]

let compact_level state index =
  let level = state.levels.(index) in
  let population = level.length in
  let sorted = Array.sub level.data 0 population in
  Array.sort Float.compare sorted;
  if index = Array.length state.levels - 1 then append_top_level state;
  let next = state.levels.(index + 1) in
  let odd = population land 1 = 1 in
  let keep_low = odd && Random.State.bool state.random in
  let first_compacted = if keep_low then 1 else 0 in
  let compacted_limit =
    if odd && not keep_low then population - 1 else population
  in
  let parity = if Random.State.bool state.random then 0 else 1 in
  let promoted_index = ref (first_compacted + parity) in
  while !promoted_index < compacted_limit do
    push next sorted.(!promoted_index);
    promoted_index := !promoted_index + 2
  done;
  if odd then (
    level.data.(0) <- if keep_low then sorted.(0) else sorted.(population - 1);
    level.length <- 1)
  else level.length <- 0

let rec first_overfull state index =
  if index = Array.length state.levels then None
  else if state.levels.(index).length > level_capacity state index then
    Some index
  else first_overfull state (index + 1)

let trim_storage state =
  Array.iteri
    (fun index level ->
      let desired = level_capacity state index + 1 in
      if Array.length level.data > desired then (
        let data = Array.make desired 0.0 in
        Array.blit level.data 0 data 0 level.length;
        level.data <- data))
    state.levels

let normalize state =
  let rec loop () =
    match first_overfull state 0 with
    | None -> ()
    | Some index ->
        compact_level state index;
        loop ()
  in
  loop ();
  trim_storage state

let add state value =
  if not (is_finite value) then Error `Non_finite
  else if Int64.equal state.count Int64.max_int then Error `Count_overflow
  else (
    push state.levels.(0) value;
    state.count <- Int64.succ state.count;
    normalize state;
    Ok ())

exception Invariant_failure of string

let check_invariants state =
  try
    if state.capacity < minimum_level_capacity then
      raise (Invariant_failure "configured capacity is below 8");
    if Array.length state.levels = 0 then
      raise (Invariant_failure "the level array is empty");
    if state.count < 0L then raise (Invariant_failure "the count is negative");
    if state.count = 0L && retained state <> 0 then
      raise (Invariant_failure "an empty sketch retains values");
    if
      Array.length state.levels > 1
      && state.levels.(Array.length state.levels - 1).length = 0
    then raise (Invariant_failure "the top level is empty");
    let total_weight = ref 0L in
    Array.iteri
      (fun index level ->
        if level.length < 0 || level.length > Array.length level.data then
          raise (Invariant_failure "a level length is outside its storage");
        if level.length > level_capacity state index then
          raise (Invariant_failure "a level exceeds its scheduled capacity");
        if Array.length level.data > level_capacity state index + 1 then
          raise (Invariant_failure "a level retains excess backing storage");
        if index >= 63 && level.length > 0 then
          raise (Invariant_failure "a non-empty level has an overflowing weight");
        let weight = Int64.shift_left 1L index in
        for item = 0 to level.length - 1 do
          if not (is_finite level.data.(item)) then
            raise (Invariant_failure "a retained value is not finite");
          if Int64.compare !total_weight (Int64.sub state.count weight) > 0 then
            raise
              (Invariant_failure
                 "retained weight exceeds the observation count");
          total_weight := Int64.add !total_weight weight
        done)
      state.levels;
    if not (Int64.equal !total_weight state.count) then
      raise
        (Invariant_failure
           "retained weight differs from the observation count");
    Ok ()
  with Invariant_failure message -> Error message
