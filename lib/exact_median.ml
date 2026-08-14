type error = [ `Non_finite ]

type t = {
  lower : Float_heap.t;
  upper : Float_heap.t;
}

let create () =
  {
    lower = Float_heap.create Float_heap.Max;
    upper = Float_heap.create Float_heap.Min;
  }

let count state =
  Int64.of_int (Float_heap.length state.lower + Float_heap.length state.upper)

let move_root source destination =
  match Float_heap.take source with
  | Some value -> Float_heap.add destination value
  | None -> assert false

let rebalance state =
  let lower_size = Float_heap.length state.lower in
  let upper_size = Float_heap.length state.upper in
  if lower_size > upper_size + 1 then move_root state.lower state.upper
  else if upper_size > lower_size then move_root state.upper state.lower

let add state value =
  if not (Float.is_finite value) then Error `Non_finite
  else (
    (match Float_heap.peek state.lower with
    | None -> Float_heap.add state.lower value
    | Some lower_max when Float.compare value lower_max <= 0 ->
        Float_heap.add state.lower value
    | Some _ -> Float_heap.add state.upper value);
    rebalance state;
    Ok ())

let midpoint lower upper =
  let half_max = Float.max_float /. 2. in
  if Float.abs lower <= half_max && Float.abs upper <= half_max then
    (lower +. upper) /. 2.
  else (lower /. 2.) +. (upper /. 2.)

let value state =
  match (Float_heap.peek state.lower, Float_heap.peek state.upper) with
  | None, None -> None
  | Some lower, None -> Some lower
  | Some lower, Some upper ->
      if Float_heap.length state.lower > Float_heap.length state.upper then
        Some lower
      else Some (midpoint lower upper)
  | None, Some _ -> assert false
