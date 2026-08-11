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
  let summary = S.create () in
  add_all summary [ -.Float.max_float; Float.max_float ];
  check_close "opposite-extrema mean" 0.
    (get_some "opposite-extrema mean" (S.mean summary))

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

let () =
  test_running_statistics ();
  test_compensated_sum ();
  test_opposite_extrema_keep_representable_mean ();
  test_rejection_is_transactional ()
