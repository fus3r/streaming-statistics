type error = [ `Non_finite | `Count_overflow ]
type merge_error = [ `Count_overflow ]

type regression = { slope : float; intercept : float }

type t = {
  mutable count : int64;
  mutable mean_x : float;
  mutable mean_y : float;
  mutable m2_x : float;
  mutable m2_y : float;
  mutable co_moment : float;
}

let create () =
  {
    count = 0L;
    mean_x = 0.;
    mean_y = 0.;
    m2_x = 0.;
    m2_y = 0.;
    co_moment = 0.;
  }

let copy t =
  {
    count = t.count;
    mean_x = t.mean_x;
    mean_y = t.mean_y;
    m2_x = t.m2_x;
    m2_y = t.m2_y;
    co_moment = t.co_moment;
  }

let count t = t.count

let update_mean ~old_count ~next_count mean value =
  let divisor = Int64.to_float next_count in
  let delta = value -. mean in
  if Float.is_finite delta then (mean +. (delta /. divisor), delta)
  else
    let old_weight = Int64.to_float old_count /. divisor in
    ((mean *. old_weight) +. (value /. divisor), delta)

let merge_mean ~left_count ~right_count ~combined_count left right delta =
  let right_weight = right_count /. combined_count in
  if Float.is_finite delta then left +. (delta *. right_weight)
  else
    let left_weight = left_count /. combined_count in
    (left *. left_weight) +. (right *. right_weight)

let product_or_zero left right =
  if left = 0. || right = 0. then 0. else left *. right

let add t x y =
  if not (Float.is_finite x && Float.is_finite y) then Error `Non_finite
  else if Int64.equal t.count Int64.max_int then Error `Count_overflow
  else
    let next_count = Int64.succ t.count in
    let next_mean_x, delta_x =
      update_mean ~old_count:t.count ~next_count t.mean_x x
    in
    let next_mean_y, delta_y =
      update_mean ~old_count:t.count ~next_count t.mean_y y
    in
    let next_m2_x = t.m2_x +. (delta_x *. (x -. next_mean_x)) in
    let next_m2_y = t.m2_y +. (delta_y *. (y -. next_mean_y)) in
    let next_co_moment =
      t.co_moment +. product_or_zero delta_x (y -. next_mean_y)
    in
    t.count <- next_count;
    t.mean_x <- next_mean_x;
    t.mean_y <- next_mean_y;
    t.m2_x <- next_m2_x;
    t.m2_y <- next_m2_y;
    t.co_moment <- next_co_moment;
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
    let right_weight = right_count /. combined_count in
    let cross_weight = left_count *. right_weight in
    let delta_x = right.mean_x -. left.mean_x in
    let delta_y = right.mean_y -. left.mean_y in
    let mean_x =
      merge_mean ~left_count ~right_count ~combined_count left.mean_x
        right.mean_x delta_x
    in
    let mean_y =
      merge_mean ~left_count ~right_count ~combined_count left.mean_y
        right.mean_y delta_y
    in
    let cross_co_moment =
      product_or_zero delta_x delta_y *. cross_weight
    in
    Ok
      {
        count;
        mean_x;
        mean_y;
        m2_x = left.m2_x +. right.m2_x +. (delta_x *. delta_x *. cross_weight);
        m2_y = left.m2_y +. right.m2_y +. (delta_y *. delta_y *. cross_weight);
        co_moment =
          left.co_moment +. right.co_moment +. cross_co_moment;
      }

let population_covariance t =
  if Int64.equal t.count 0L then None
  else Some (t.co_moment /. Int64.to_float t.count)

let sample_covariance t =
  if Int64.compare t.count 2L < 0 then None
  else Some (t.co_moment /. Int64.to_float (Int64.pred t.count))

let correlation_rounding_tolerance = 8. *. Float.epsilon

let correlation t =
  if
    Int64.compare t.count 2L < 0
    || Float.compare t.m2_x 0. <= 0
    || Float.compare t.m2_y 0. <= 0
  then None
  else
    let value =
      (t.co_moment /. Float.sqrt t.m2_x) /. Float.sqrt t.m2_y
    in
    if not (Float.is_finite value) then None
    else if value > 1. then
      if value <= 1. +. correlation_rounding_tolerance then Some 1. else None
    else if value < -1. then
      if value >= -1. -. correlation_rounding_tolerance then Some (-1.) else None
    else Some value

let linear_regression t =
  if Int64.compare t.count 2L < 0 || Float.compare t.m2_x 0. <= 0 then None
  else
    let slope = t.co_moment /. t.m2_x in
    let intercept = t.mean_y -. (slope *. t.mean_x) in
    if Float.is_finite slope && Float.is_finite intercept then
      Some { slope; intercept }
    else None
