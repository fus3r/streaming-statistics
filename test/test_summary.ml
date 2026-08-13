module S = Streaming_statistics.Summary

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

let add_all summary values =
  List.iter
    (fun value ->
      match S.add summary value with
      | Ok () -> ()
      | Error _ -> failf "unexpected add error for %.17g" value)
    values

let test_running_statistics () =
  let summary = S.create () in
  if S.count summary <> 0L then failwith "empty count must be zero";
  check_close "empty sum" 0. (S.sum summary);
  if S.min summary <> None then failwith "empty minimum must be undefined";
  if S.max summary <> None then failwith "empty maximum must be undefined";
  if S.mean summary <> None then failwith "empty mean must be undefined";
  if S.population_variance summary <> None then
    failwith "empty population variance must be undefined";
  if S.sample_variance summary <> None then
    failwith "empty sample variance must be undefined";
  if S.population_standard_deviation summary <> None then
    failwith "empty population standard deviation must be undefined";
  if S.sample_standard_deviation summary <> None then
    failwith "empty sample standard deviation must be undefined";
  add_all summary [ 1.; 2.; 3.; 4. ];
  if not (Int64.equal (S.count summary) 4L) then
    failwith "wrong observation count";
  check_close "sum" 10. (S.sum summary);
  check_close "minimum" 1. (get_some "minimum" (S.min summary));
  check_close "maximum" 4. (get_some "maximum" (S.max summary));
  check_close "mean" 2.5 (get_some "mean" (S.mean summary));
  check_close "population variance" 1.25
    (get_some "population variance" (S.population_variance summary));
  check_close "sample variance" (5. /. 3.)
    (get_some "sample variance" (S.sample_variance summary));
  check_close "population standard deviation" (Float.sqrt 1.25)
    (get_some "population standard deviation"
       (S.population_standard_deviation summary));
  check_close "sample standard deviation" (Float.sqrt (5. /. 3.))
    (get_some "sample standard deviation" (S.sample_standard_deviation summary))

let test_compensated_sum () =
  let summary = S.create () in
  add_all summary [ 1e16; 1.; -1e16 ];
  check_close "compensated sum" 1. (S.sum summary)

let test_opposite_extrema_keep_representable_mean () =
  let sequential = S.create () in
  add_all sequential [ -.Float.max_float; Float.max_float ];
  check_close "opposite-extrema mean" 0.
    (get_some "opposite-extrema mean" (S.mean sequential));
  let left = S.create () in
  let right = S.create () in
  add_all left [ -.Float.max_float ];
  add_all right [ Float.max_float ];
  let merged =
    match S.merge left right with
    | Ok summary -> summary
    | Error _ -> failwith "opposite extrema failed to merge"
  in
  check_close "merged opposite-extrema mean" 0.
    (get_some "merged opposite-extrema mean" (S.mean merged))

let test_rejection_is_transactional () =
  let summary = S.create () in
  add_all summary [ 2.; 4. ];
  let before =
    (S.count summary, S.sum summary, S.min summary, S.max summary, S.mean summary,
     S.population_variance summary)
  in
  let reject value =
    match S.add summary value with
    | Error `Non_finite -> ()
    | Error `Count_overflow -> failwith "unexpected count overflow"
    | Ok () -> failwith "non-finite input was not rejected"
  in
  reject Float.nan;
  reject Float.infinity;
  reject Float.neg_infinity;
  if
    before
    <>
    (S.count summary, S.sum summary, S.min summary, S.max summary, S.mean summary,
     S.population_variance summary)
  then failwith "rejected input changed the summary"

let test_merge_is_pure () =
  let left = S.create () in
  let right = S.create () in
  let monolithic = S.create () in
  add_all left [ 1.; 2. ];
  add_all right [ 3.; 4. ];
  add_all monolithic [ 1.; 2.; 3.; 4. ];
  let left_before = (S.count left, S.sum left, S.mean left) in
  let right_before = (S.count right, S.sum right, S.mean right) in
  let merged =
    match S.merge left right with
    | Ok summary -> summary
    | Error _ -> failwith "unexpected merge error"
  in
  if S.count merged <> S.count monolithic then failwith "merged count differs";
  check_close "partitioned sum" (S.sum monolithic) (S.sum merged);
  check_close "partitioned minimum"
    (get_some "monolithic minimum" (S.min monolithic))
    (get_some "partitioned minimum" (S.min merged));
  check_close "partitioned maximum"
    (get_some "monolithic maximum" (S.max monolithic))
    (get_some "partitioned maximum" (S.max merged));
  check_close "partitioned mean"
    (get_some "monolithic mean" (S.mean monolithic))
    (get_some "partitioned mean" (S.mean merged));
  check_close "partitioned variance"
    (get_some "monolithic variance" (S.population_variance monolithic))
    (get_some "partitioned variance" (S.population_variance merged));
  if left_before <> (S.count left, S.sum left, S.mean left) then
    failwith "merge changed its left input";
  if right_before <> (S.count right, S.sum right, S.mean right) then
    failwith "merge changed its right input";
  add_all merged [ 5. ];
  if S.count left <> 2L then failwith "merged state aliases its left input"

let test_empty_partition_merge () =
  let populated = S.create () in
  let empty = S.create () in
  add_all populated [ 1.; 2.; 3.; 4. ];
  let merge_ok left right =
    match S.merge left right with
    | Ok summary -> summary
    | Error _ -> failwith "empty partition merge failed"
  in
  let results = [ merge_ok empty populated; merge_ok populated empty ] in
  List.iter
    (fun merged ->
      if S.count merged <> S.count populated then
        failwith "empty partition changed the count";
      check_close "empty-partition sum" (S.sum populated) (S.sum merged);
      check_close "empty-partition mean"
        (get_some "populated mean" (S.mean populated))
        (get_some "empty-partition mean" (S.mean merged));
      check_close "empty-partition variance"
        (get_some "populated variance" (S.population_variance populated))
        (get_some "empty-partition variance" (S.population_variance merged));
      add_all merged [ 5. ])
    results;
  if S.count populated <> 4L then
    failwith "empty partition merge aliases its populated input"

let test_count_overflow () =
  let initial = S.create () in
  add_all initial [ 1. ];
  let merge_ok left right =
    match S.merge left right with
    | Ok merged -> merged
    | Error _ -> failwith "count overflow reported too early"
  in
  let rec double state remaining =
    if remaining = 0 then state
    else double (merge_ok state state) (remaining - 1)
  in
  let large = double initial 62 in
  if not (Int64.equal (S.count large) 4_611_686_018_427_387_904L) then
    failwith "unexpected count before overflow";
  let before = (S.count large, S.sum large, S.mean large) in
  (match S.merge large large with
  | Error `Count_overflow -> ()
  | Ok _ -> failwith "overflowing merge was not rejected");
  if before <> (S.count large, S.sum large, S.mean large) then
    failwith "overflowing merge changed its input";
  let rec fill_bits total power remaining =
    if remaining = 0 then total
    else
      let next_power = merge_ok power power in
      fill_bits (merge_ok total next_power) next_power (remaining - 1)
  in
  let full = fill_bits initial initial 62 in
  if not (Int64.equal (S.count full) Int64.max_int) then
    failwith "failed to construct the maximum count";
  let before = (S.count full, S.sum full, S.mean full) in
  (match S.add full 1. with
  | Error `Count_overflow -> ()
  | Error `Non_finite -> failwith "unexpected non-finite add error"
  | Ok () -> failwith "overflowing add was not rejected");
  if before <> (S.count full, S.sum full, S.mean full) then
    failwith "overflowing add changed the summary"

let () =
  test_running_statistics ();
  test_compensated_sum ();
  test_opposite_extrema_keep_representable_mean ();
  test_rejection_is_transactional ();
  test_merge_is_pure ();
  test_empty_partition_merge ();
  test_count_overflow ()
