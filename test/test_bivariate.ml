module B = Streaming_statistics.Bivariate

let failf format = Printf.ksprintf failwith format

let check_close ?(epsilon = 1e-12) label expected actual =
  let scale = Float.max 1. (Float.max (Float.abs expected) (Float.abs actual)) in
  if
    not (Float.is_finite actual)
    || Float.abs (expected -. actual) > epsilon *. scale
  then
    failf "%s: expected %.17g, got %.17g" label expected actual

let get_some label = function
  | Some value -> value
  | None -> failf "%s: expected a value" label

let add_all stats pairs =
  List.iter
    (fun (x, y) ->
      match B.add stats x y with
      | Ok () -> ()
      | Error _ -> failf "unexpected add error for (%.17g, %.17g)" x y)
    pairs

let test_covariance_correlation_and_regression () =
  let stats = B.create () in
  if B.population_covariance stats <> None then
    failwith "empty covariance must be undefined";
  if B.sample_covariance stats <> None then
    failwith "empty sample covariance must be undefined";
  if B.correlation stats <> None then
    failwith "empty correlation must be undefined";
  if B.linear_regression stats <> None then
    failwith "empty regression must be undefined";
  add_all stats [ (1., 3.) ];
  if B.sample_covariance stats <> None then
    failwith "single-pair sample covariance must be undefined";
  if B.correlation stats <> None then
    failwith "single-pair correlation must be undefined";
  if B.linear_regression stats <> None then
    failwith "single-pair regression must be undefined";
  add_all stats [ (2., 5.); (3., 7.); (4., 9.) ];
  if not (Int64.equal (B.count stats) 4L) then
    failwith "wrong pair count";
  check_close "population covariance" 2.5
    (get_some "population covariance" (B.population_covariance stats));
  check_close "sample covariance" (10. /. 3.)
    (get_some "sample covariance" (B.sample_covariance stats));
  check_close "correlation" 1.
    (get_some "correlation" (B.correlation stats));
  let regression =
    get_some "linear regression" (B.linear_regression stats)
  in
  let { B.slope; intercept } = regression in
  check_close "slope" 2. slope;
  check_close "intercept" 1. intercept

let test_degenerate_regression () =
  let stats = B.create () in
  add_all stats [ (2., 1.); (2., 3.) ];
  if B.correlation stats <> None then
    failwith "correlation with constant x must be undefined";
  if B.linear_regression stats <> None then
    failwith "regression with constant x must be undefined"

let test_extreme_scale_and_correlation_range () =
  let constant_y = B.create () in
  add_all constant_y [ (-.Float.max_float, 1.); (Float.max_float, 1.) ];
  check_close "extreme-scale covariance" 0.
    (get_some "extreme-scale covariance"
       (B.population_covariance constant_y));
  let regression =
    get_some "extreme-scale regression" (B.linear_regression constant_y)
  in
  let { B.slope; intercept } = regression in
  check_close "extreme-scale slope" 0. slope;
  check_close "extreme-scale intercept" 1. intercept;
  let identical = B.create () in
  add_all identical [ (-10., -10.); (-3.7, -3.7) ];
  check_close "correlation upper bound" 1.
    (get_some "correlation upper bound" (B.correlation identical))

let test_material_correlation_overshoot_is_undefined () =
  let stats = B.create () in
  add_all stats
    [
      (100000000.00000086, 100000000.00000022);
      (100000000.00000082, 100000000.00000057);
      (100000000.00000092, 100000000.00000001);
    ];
  if B.correlation stats <> None then
    failwith "material correlation overshoot must not be clamped"

let test_rejection_is_transactional () =
  let stats = B.create () in
  add_all stats [ (1., 2.); (2., 4.) ];
  let before =
    (B.count stats, B.population_covariance stats,
     B.correlation stats, B.linear_regression stats)
  in
  let reject x y =
    match B.add stats x y with
    | Error `Non_finite -> ()
    | Error `Count_overflow -> failwith "unexpected count overflow"
    | Ok () -> failwith "non-finite pair was not rejected"
  in
  reject Float.nan 3.;
  reject 3. Float.infinity;
  if
    before
    <>
    (B.count stats, B.population_covariance stats,
     B.correlation stats, B.linear_regression stats)
  then failwith "rejected pair changed the accumulator"

let test_merge_is_pure () =
  let left = B.create () in
  let right = B.create () in
  add_all left [ (1., 3.); (2., 5.) ];
  add_all right [ (3., 7.); (4., 9.) ];
  let left_before =
    (B.count left, B.population_covariance left)
  in
  let right_before =
    (B.count right, B.population_covariance right)
  in
  let merged =
    match B.merge left right with
    | Ok stats -> stats
    | Error _ -> failwith "unexpected merge error"
  in
  check_close "merged covariance" 2.5
    (get_some "merged covariance" (B.population_covariance merged));
  let regression =
    get_some "merged regression" (B.linear_regression merged)
  in
  let { B.slope; intercept } = regression in
  check_close "merged slope" 2. slope;
  check_close "merged intercept" 1. intercept;
  if left_before <> (B.count left, B.population_covariance left)
  then failwith "merge changed its left input";
  if
    right_before
    <> (B.count right, B.population_covariance right)
  then failwith "merge changed its right input";
  (match B.add merged 5. 11. with
  | Ok () -> ()
  | Error _ -> failwith "unexpected add error after merge");
  if not (Int64.equal (B.count left) 2L) then
    failwith "merged state aliases its left input"

let test_count_overflow () =
  let initial = B.create () in
  add_all initial [ (1., 2.) ];
  let merge_ok left right =
    match B.merge left right with
    | Ok merged -> merged
    | Error _ -> failwith "count overflow reported too early"
  in
  let rec double state remaining =
    if remaining = 0 then state
    else double (merge_ok state state) (remaining - 1)
  in
  let large = double initial 62 in
  if not (Int64.equal (B.count large) 4_611_686_018_427_387_904L) then
    failwith "unexpected count before overflow";
  (match B.merge large large with
  | Error `Count_overflow -> ()
  | Ok _ -> failwith "overflowing merge was not rejected");
  let rec fill_bits total power remaining =
    if remaining = 0 then total
    else
      let next_power = merge_ok power power in
      fill_bits (merge_ok total next_power) next_power (remaining - 1)
  in
  let full = fill_bits initial initial 62 in
  if not (Int64.equal (B.count full) Int64.max_int) then
    failwith "failed to construct the maximum count";
  let before =
    (B.count full, B.population_covariance full, B.linear_regression full)
  in
  (match B.add full 1. 2. with
  | Error `Count_overflow -> ()
  | Error `Non_finite -> failwith "unexpected non-finite add error"
  | Ok () -> failwith "overflowing add was not rejected");
  if
    before
    <> (B.count full, B.population_covariance full, B.linear_regression full)
  then failwith "overflowing add changed the accumulator"

let () =
  test_covariance_correlation_and_regression ();
  test_degenerate_regression ();
  test_extreme_scale_and_correlation_range ();
  test_material_correlation_overshoot_is_undefined ();
  test_rejection_is_transactional ();
  test_merge_is_pure ();
  test_count_overflow ()
