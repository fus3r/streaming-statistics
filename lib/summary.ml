type error = [ `Non_finite | `Count_overflow ]
type merge_error = [ `Count_overflow ]

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

let copy t =
  {
    count = t.count;
    minimum = t.minimum;
    maximum = t.maximum;
    total = t.total;
    correction = t.correction;
    mean = t.mean;
    m2 = t.m2;
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

let merge_mean ~left_count ~right_count ~combined_count left right delta =
  let right_weight = right_count /. combined_count in
  if Float.is_finite delta then (left +. (delta *. right_weight), right_weight)
  else
    let left_weight = left_count /. combined_count in
    ((left *. left_weight) +. (right *. right_weight), right_weight)

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

let count_sum_overflows left right =
  Int64.compare left (Int64.sub Int64.max_int right) > 0

let merge left right : (t, merge_error) result =
  if count_sum_overflows left.count right.count then Error `Count_overflow
  else if Int64.equal left.count 0L then Ok (copy right)
  else if Int64.equal right.count 0L then Ok (copy left)
  else
    let count = Int64.add left.count right.count in
    let left_count = Int64.to_float left.count in
    let right_count = Int64.to_float right.count in
    let combined_count = Int64.to_float count in
    let delta = right.mean -. left.mean in
    let mean, right_weight =
      merge_mean ~left_count ~right_count ~combined_count left.mean right.mean
        delta
    in
    let m2 =
      left.m2 +. right.m2 +. (delta *. delta *. (left_count *. right_weight))
    in
    let total, correction = compensated_add 0. 0. left.total in
    let total, correction =
      compensated_add total correction left.correction
    in
    let total, correction = compensated_add total correction right.total in
    let total, correction =
      compensated_add total correction right.correction
    in
    let minimum =
      match (left.minimum, right.minimum) with
      | Some a, Some b -> Some (Float.min a b)
      | _ -> assert false
    in
    let maximum =
      match (left.maximum, right.maximum) with
      | Some a, Some b -> Some (Float.max a b)
      | _ -> assert false
    in
    Ok
      {
        count;
        minimum;
        maximum;
        total;
        correction;
        mean;
        m2;
      }

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
