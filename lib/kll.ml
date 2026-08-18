type level = { mutable data : float array; mutable length : int }

type t = {
  capacity : int;
  random : Random.State.t;
  mutable count : int64;
  mutable levels : level array;
  mutable minimum : float;
  mutable maximum : float;
}

type add_error = [ `Non_finite | `Count_overflow ]

type merge_error =
  [ `Incompatible_capacity of int * int | `Count_overflow ]

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
    minimum = nan;
    maximum = nan;
  }

let capacity state = state.capacity
let count state = state.count

let retained state =
  Array.fold_left (fun total level -> total + level.length) 0 state.levels

let minimum state =
  if Int64.equal state.count 0L then None else Some state.minimum

let maximum state =
  if Int64.equal state.count 0L then None else Some state.maximum

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

let update_extrema state value =
  if Int64.equal state.count 0L then (
    state.minimum <- value;
    state.maximum <- value)
  else (
    if Float.compare value state.minimum < 0 then state.minimum <- value;
    if Float.compare value state.maximum > 0 then state.maximum <- value)

let add state value =
  if not (is_finite value) then Error `Non_finite
  else if Int64.equal state.count Int64.max_int then Error `Count_overflow
  else (
    update_extrema state value;
    push state.levels.(0) value;
    state.count <- Int64.succ state.count;
    normalize state;
    Ok ())

type weighted = { value : float; weight : int64 }

let weighted_items state =
  let items = Array.make (retained state) { value = 0.0; weight = 0L } in
  let output = ref 0 in
  Array.iteri
    (fun index level ->
      if index >= 63 && level.length > 0 then
        invalid_arg "Kll: weighted level exceeds Int64.t";
      let weight = Int64.shift_left 1L index in
      for item = 0 to level.length - 1 do
        items.(!output) <- { value = level.data.(item); weight };
        incr output
      done)
    state.levels;
  Array.sort (fun left right -> Float.compare left.value right.value) items;
  items

let require_finite caller value =
  if not (is_finite value) then
    invalid_arg (caller ^ ": expected a finite floating-point value")

let rank state value =
  require_finite "Kll.rank" value;
  if Int64.equal state.count 0L then None
  else
    let cumulative = ref 0L in
    let items = weighted_items state in
    let index = ref 0 in
    while
      !index < Array.length items
      && Float.compare items.(!index).value value <= 0
    do
      cumulative := Int64.add !cumulative items.(!index).weight;
      incr index
    done;
    Some (Int64.to_float !cumulative /. Int64.to_float state.count)

let limb_bits = 30
let limb_mask = Int64.pred (Int64.shift_left 1L limb_bits)

let positive_int64_limbs value =
  [|
    Int64.logand value limb_mask;
    Int64.logand (Int64.shift_right_logical value limb_bits) limb_mask;
    Int64.shift_right_logical value (2 * limb_bits);
  |]

let mantissa_limbs value =
  [|
    Int64.logand value limb_mask;
    Int64.shift_right_logical value limb_bits;
  |]

let multiply_limbs left right =
  let product = Array.make (Array.length left + Array.length right + 1) 0L in
  Array.iteri
    (fun left_index left_limb ->
      Array.iteri
        (fun right_index right_limb ->
          let index = left_index + right_index in
          product.(index) <-
            Int64.add product.(index) (Int64.mul left_limb right_limb))
        right)
    left;
  for index = 0 to Array.length product - 2 do
    let carry = Int64.shift_right_logical product.(index) limb_bits in
    product.(index) <- Int64.logand product.(index) limb_mask;
    product.(index + 1) <- Int64.add product.(index + 1) carry
  done;
  product

let shift_limbs_right limbs shift =
  let first_limb = shift / limb_bits in
  if first_limb >= Array.length limbs then 0L
  else
    let offset = shift mod limb_bits in
    let output_length = Array.length limbs - first_limb in
    let output = Array.make output_length 0L in
    for index = 0 to output_length - 1 do
      let source = first_limb + index in
      let lower = Int64.shift_right_logical limbs.(source) offset in
      let upper =
        if offset = 0 || source + 1 >= Array.length limbs then 0L
        else
          let upper_mask = Int64.pred (Int64.shift_left 1L offset) in
          Int64.shift_left
            (Int64.logand limbs.(source + 1) upper_mask)
            (limb_bits - offset)
      in
      output.(index) <- Int64.logor lower upper
    done;
    Array.fold_right
      (fun limb result ->
        Int64.logor (Int64.shift_left result limb_bits) limb)
      output 0L

let lower_quantile_target count q =
  let last_index = Int64.pred count in
  if q = 0.0 then 0L
  else if q = 1.0 then last_index
  else
    let bits = Int64.bits_of_float q in
    let exponent =
      Int64.to_int
        (Int64.logand (Int64.shift_right_logical bits 52) 0x7ffL)
    in
    let fraction = Int64.logand bits 0x000f_ffff_ffff_ffffL in
    let mantissa, shift =
      if exponent = 0 then (fraction, 1_074)
      else (Int64.logor fraction 0x0010_0000_0000_0000L, 1_075 - exponent)
    in
    multiply_limbs (positive_int64_limbs last_index)
      (mantissa_limbs mantissa)
    |> fun product -> shift_limbs_right product shift

let quantile state ~q =
  require_finite "Kll.quantile" q;
  if q < 0.0 || q > 1.0 then
    invalid_arg "Kll.quantile: q must lie in the closed interval [0, 1]";
  if Int64.equal state.count 0L then None
  else if q = 0.0 then Some state.minimum
  else if q = 1.0 then Some state.maximum
  else
    let items = weighted_items state in
    let target = lower_quantile_target state.count q in
    let cumulative = ref 0L in
    let index = ref 0 in
    while
      !index < Array.length items - 1
      && Int64.compare
           (Int64.add !cumulative items.(!index).weight)
           target
         <= 0
    do
      cumulative := Int64.add !cumulative items.(!index).weight;
      incr index
    done;
    Some items.(!index).value

let copy_level_items source target =
  for index = 0 to source.length - 1 do
    push target source.data.(index)
  done

let merge ~seed left right =
  if left.capacity <> right.capacity then
    Error (`Incompatible_capacity (left.capacity, right.capacity))
  else if Int64.compare left.count (Int64.sub Int64.max_int right.count) > 0
  then Error `Count_overflow
  else
    let merged = create ~capacity:left.capacity ~seed () in
    let number_of_levels =
      Int.max (Array.length left.levels) (Array.length right.levels)
    in
    while Array.length merged.levels < number_of_levels do
      append_top_level merged
    done;
    Array.iteri
      (fun index level -> copy_level_items level merged.levels.(index))
      left.levels;
    Array.iteri
      (fun index level -> copy_level_items level merged.levels.(index))
      right.levels;
    merged.count <- Int64.add left.count right.count;
    if not (Int64.equal merged.count 0L) then (
      if Int64.equal left.count 0L then (
        merged.minimum <- right.minimum;
        merged.maximum <- right.maximum)
      else if Int64.equal right.count 0L then (
        merged.minimum <- left.minimum;
        merged.maximum <- left.maximum)
      else (
        merged.minimum <- Float.min left.minimum right.minimum;
        merged.maximum <- Float.max left.maximum right.maximum));
    normalize merged;
    Ok merged

exception Invariant_failure of string

let check_invariants state =
  try
    if state.capacity < minimum_level_capacity then
      raise (Invariant_failure "configured capacity is below 8");
    if Array.length state.levels = 0 then
      raise (Invariant_failure "the level array is empty");
    if state.count < 0L then raise (Invariant_failure "the count is negative");
    if Int64.equal state.count 0L then (
      if retained state <> 0 then
        raise (Invariant_failure "an empty sketch retains values"))
    else (
      if not (is_finite state.minimum && is_finite state.maximum) then
        raise (Invariant_failure "non-finite extrema in a non-empty sketch");
      if Float.compare state.minimum state.maximum > 0 then
        raise (Invariant_failure "minimum exceeds maximum"));
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
          let value = level.data.(item) in
          if not (is_finite value) then
            raise (Invariant_failure "a retained value is not finite");
          if
            (not (Int64.equal state.count 0L))
            && (Float.compare value state.minimum < 0
               || Float.compare value state.maximum > 0)
          then
            raise (Invariant_failure "a retained value lies outside the extrema");
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
