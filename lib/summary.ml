type error = [ `Non_finite | `Count_overflow ]

type t = {
  mutable count : int64;
  mutable minimum : float option;
  mutable maximum : float option;
  mutable total : float;
  mutable correction : float;
  mutable mean : float;
  mutable m2 : float;
}

let create () =
  {
    count = 0L;
    minimum = None;
    maximum = None;
    total = 0.;
    correction = 0.;
    mean = 0.;
    m2 = 0.;
  }

let count t = t.count

(* Neumaier compensation also handles an addend larger than the running sum. *)
let compensated_add total correction x =
  let next = total +. x in
  let roundoff =
    if Float.abs total >= Float.abs x then (total -. next) +. x
    else (x -. next) +. total
  in
  (next, correction +. roundoff)

let update_mean ~old_count ~next_count mean x =
  let divisor = Int64.to_float next_count in
  let delta = x -. mean in
  if Float.is_finite delta then (mean +. (delta /. divisor), delta)
  else
    let old_weight = Int64.to_float old_count /. divisor in
    ((mean *. old_weight) +. (x /. divisor), delta)

let add t x =
  if not (Float.is_finite x) then Error `Non_finite
  else if Int64.equal t.count Int64.max_int then Error `Count_overflow
  else
    let next_count = Int64.succ t.count in
    let next_total, next_correction =
      compensated_add t.total t.correction x
    in
    let next_minimum =
      match t.minimum with None -> Some x | Some value -> Some (Float.min value x)
    in
    let next_maximum =
      match t.maximum with None -> Some x | Some value -> Some (Float.max value x)
    in
    let next_mean, next_m2 =
      if Int64.equal t.count 0L then (x, 0.)
      else
        let updated_mean, delta =
          update_mean ~old_count:t.count ~next_count t.mean x
        in
        (updated_mean, t.m2 +. (delta *. (x -. updated_mean)))
    in
    t.count <- next_count;
    t.minimum <- next_minimum;
    t.maximum <- next_maximum;
    t.total <- next_total;
    t.correction <- next_correction;
    t.mean <- next_mean;
    t.m2 <- next_m2;
    Ok ()

let sum t = t.total +. t.correction
let min t = t.minimum
let max t = t.maximum
let mean t = if Int64.equal t.count 0L then None else Some t.mean

let population_variance t =
  if Int64.equal t.count 0L then None
  else Some (t.m2 /. Int64.to_float t.count)

let sample_variance t =
  if Int64.compare t.count 2L < 0 then None
  else Some (t.m2 /. Int64.to_float (Int64.pred t.count))

let population_standard_deviation t =
  Option.map Float.sqrt (population_variance t)

let sample_standard_deviation t = Option.map Float.sqrt (sample_variance t)
