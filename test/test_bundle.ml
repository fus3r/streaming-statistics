open Streaming_statistics

let fail message = failwith message

let expect_ok = function Ok () -> () | Error _ -> fail "unexpected add error"

let get_some = function
  | Some value -> value
  | None -> fail "expected a defined statistic"

let check_close expected actual =
  if not (Float.is_finite actual) || Float.abs (expected -. actual) > 1e-12 then
    fail (Printf.sprintf "expected %.17g, got %.17g" expected actual)

let check_option_close expected actual =
  match (expected, actual) with
  | None, None -> ()
  | Some expected, Some actual -> check_close expected actual
  | _ -> fail "expected matching optional statistics"

let snapshot bundle =
  ( Bundle.count bundle,
    Bundle.sum bundle,
    Bundle.min bundle,
    Bundle.max bundle,
    Bundle.mean bundle,
    Bundle.population_variance bundle,
    Bundle.sample_variance bundle,
    Bundle.exact_median bundle,
    Bundle.reservoir_sample bundle,
    Bundle.approximate_quantile bundle ~q:0.5,
    Bundle.kll_retained bundle )

let test_enabled_components () =
  let bundle =
    match
      Bundle.create ~exact_median:true
        ~reservoir:{ capacity = 3; seed = 17 }
        ~kll:{ capacity = 16; seed = 29 }
        ()
    with
    | Ok bundle -> bundle
    | Error _ -> fail "valid bundle configuration was rejected"
  in
  List.iter (fun value -> expect_ok (Bundle.add bundle value))
    [ 5.; 2.; 10.; 4.; 9. ];
  if Bundle.count bundle <> 5L then fail "bundle count is wrong";
  check_close 6. (get_some (Bundle.mean bundle));
  (match Bundle.exact_median bundle with
  | Bundle.Enabled median -> check_close 5. (get_some median)
  | Bundle.Disabled -> fail "exact median should be enabled");
  (match Bundle.approximate_quantile bundle ~q:0.5 with
  | Bundle.Enabled quantile -> check_close 5. (get_some quantile)
  | Bundle.Disabled -> fail "KLL should be enabled");
  (match Bundle.reservoir_sample bundle with
  | Bundle.Enabled sample when Array.length sample = 3 -> ()
  | _ -> fail "reservoir should contain three items");
  let before = snapshot bundle in
  (match Bundle.add bundle Float.nan with
  | Error `Non_finite -> ()
  | _ -> fail "bundle accepted NaN");
  if before <> snapshot bundle then
    fail "rejected input changed the bundle"

let test_disabled_components_and_configuration () =
  let bundle =
    match Bundle.create () with
    | Ok bundle -> bundle
    | Error _ -> fail "default bundle configuration was rejected"
  in
  if Bundle.exact_median bundle <> Bundle.Disabled then
    fail "exact median should be disabled by default";
  if Bundle.kll_retained bundle <> Bundle.Disabled then
    fail "KLL should be disabled by default";
  (match Bundle.create ~reservoir:{ capacity = 0; seed = 1 } () with
  | Error (Bundle.Invalid_reservoir_capacity 0) -> ()
  | _ -> fail "invalid reservoir capacity was not reported");
  match Bundle.create ~kll:{ capacity = 7; seed = 1 } () with
  | Error (Bundle.Invalid_kll_capacity 7) -> ()
  | _ -> fail "invalid KLL capacity was not reported"

let test_matches_independent_components () =
  let reservoir_config = { Bundle.capacity = 7; seed = 2026 } in
  let kll_config = { Bundle.capacity = 16; seed = 811 } in
  let bundle =
    match
      Bundle.create ~exact_median:true ~reservoir:reservoir_config
        ~kll:kll_config ()
    with
    | Ok bundle -> bundle
    | Error _ -> fail "valid bundle configuration was rejected"
  in
  let summary = Summary.create () in
  let exact_median = Exact_median.create () in
  let reservoir =
    match
      Reservoir.create ~capacity:reservoir_config.capacity
        ~seed:reservoir_config.seed
    with
    | Ok reservoir -> reservoir
    | Error _ -> fail "valid reservoir configuration was rejected"
  in
  let kll =
    Kll.create ~capacity:kll_config.capacity ~seed:kll_config.seed ()
  in
  let observations =
    List.init 64 (fun index ->
        Float.of_int (((index * 37) mod 23) - 11))
  in
  List.iter
    (fun value ->
      expect_ok (Bundle.add bundle value);
      expect_ok (Summary.add summary value);
      expect_ok (Exact_median.add exact_median value);
      expect_ok (Reservoir.add reservoir value);
      expect_ok (Kll.add kll value))
    observations;
  if Bundle.count bundle <> Summary.count summary then
    fail "bundle count differs from Summary";
  check_close (Summary.sum summary) (Bundle.sum bundle);
  check_option_close (Summary.min summary) (Bundle.min bundle);
  check_option_close (Summary.max summary) (Bundle.max bundle);
  check_option_close (Summary.mean summary) (Bundle.mean bundle);
  check_option_close
    (Summary.population_variance summary)
    (Bundle.population_variance bundle);
  check_option_close
    (Summary.sample_variance summary)
    (Bundle.sample_variance bundle);
  (match Bundle.exact_median bundle with
  | Bundle.Enabled value ->
      check_option_close (Exact_median.value exact_median) value
  | Bundle.Disabled -> fail "exact median should be enabled");
  (match Bundle.reservoir_sample bundle with
  | Bundle.Enabled sample when sample = Reservoir.sample reservoir -> ()
  | Bundle.Enabled _ -> fail "bundle reservoir differs from Reservoir"
  | Bundle.Disabled -> fail "reservoir should be enabled");
  List.iter
    (fun q ->
      match Bundle.approximate_quantile bundle ~q with
      | Bundle.Enabled value -> check_option_close (Kll.quantile kll ~q) value
      | Bundle.Disabled -> fail "KLL should be enabled")
    [ 0.0; 0.1; 0.5; 0.9; 1.0 ];
  match Bundle.kll_retained bundle with
  | Bundle.Enabled retained when retained = Kll.retained kll -> ()
  | Bundle.Enabled _ -> fail "bundle retained count differs from KLL"
  | Bundle.Disabled -> fail "KLL should be enabled"

let () =
  test_enabled_components ();
  test_disabled_components_and_configuration ();
  test_matches_independent_components ()
