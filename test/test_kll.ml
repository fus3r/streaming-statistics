module Kll = Streaming_statistics.Kll

let failf format = Printf.ksprintf failwith format

let check condition format =
  Printf.ksprintf (fun message -> if not condition then failwith message) format

let check_float ?(epsilon = 1e-12) expected actual label =
  if not (Float.is_finite actual) || Float.abs (expected -. actual) > epsilon then
    failf "%s: expected %.17g, got %.17g" label expected actual

let get_some label = function
  | Some value -> value
  | None -> failf "%s: expected Some" label

let expect_ok = function
  | Ok () -> ()
  | Error `Non_finite -> failwith "unexpected non-finite KLL input"
  | Error `Count_overflow -> failwith "unexpected KLL count overflow"

let expect_invalid_argument thunk =
  match thunk () with
  | exception Invalid_argument _ -> ()
  | _ -> failwith "expected Invalid_argument"

let check_invariants sketch =
  match Kll.check_invariants sketch with
  | Ok () -> ()
  | Error message -> failf "KLL invariant failure: %s" message

let test_capacity_and_empty_state () =
  expect_invalid_argument (fun () -> Kll.create ~capacity:7 ~seed:0 ());
  expect_invalid_argument (fun () ->
      Kll.create ~capacity:Sys.max_array_length ~seed:0 ());
  let sketch = Kll.create ~capacity:8 ~seed:20260817 () in
  check (Kll.capacity sketch = 8) "configured capacity changed";
  check (Kll.count sketch = 0L) "new sketch count is not zero";
  check (Kll.retained sketch = 0) "new sketch retains values";
  check_invariants sketch

let test_first_compaction_boundary () =
  let sketch = Kll.create ~capacity:8 ~seed:17 () in
  for index = 1 to 8 do
    expect_ok (Kll.add sketch (Float.of_int index));
    check
      (Kll.count sketch = Int64.of_int index)
      "count mismatch before first compaction at %d" index;
    check
      (Kll.retained sketch = index)
      "value compacted before level zero overflowed at %d" index;
    check_invariants sketch
  done;
  expect_ok (Kll.add sketch 9.0);
  check (Kll.count sketch = 9L) "first compaction changed the count";
  check (Kll.retained sketch = 5)
    "an odd nine-item compaction should retain one and promote four";
  check_invariants sketch

let test_weight_conservation_across_levels () =
  let sketch = Kll.create ~capacity:24 ~seed:41 () in
  for index = 0 to 4_999 do
    let value = Float.of_int ((index * 37) mod 257) in
    expect_ok (Kll.add sketch value);
    if index mod 97 = 0 then check_invariants sketch
  done;
  check (Kll.count sketch = 5_000L) "long-stream count mismatch";
  check (Kll.retained sketch < 5_000)
    "long stream did not compact any values";
  check_invariants sketch

let test_non_finite_rejection_is_atomic () =
  let sketch = Kll.create ~capacity:8 ~seed:7 () in
  List.iter (fun value -> expect_ok (Kll.add sketch value))
    [ 3.0; -0.0; Float.min_float; Float.max_float ];
  let before = (Kll.count sketch, Kll.retained sketch) in
  List.iter
    (fun value ->
      match Kll.add sketch value with
      | Error `Non_finite -> ()
      | Error `Count_overflow -> failwith "non-finite input reported overflow"
      | Ok () -> failwith "KLL accepted a non-finite value")
    [ nan; infinity; neg_infinity ];
  check
    (before = (Kll.count sketch, Kll.retained sketch))
    "rejected input changed the KLL state";
  check_invariants sketch

let add_values sketch values =
  Array.iter (fun value -> expect_ok (Kll.add sketch value)) values

let make_range ~capacity ~seed first last =
  let sketch = Kll.create ~capacity ~seed () in
  for value = first to last do
    expect_ok (Kll.add sketch (Float.of_int value))
  done;
  sketch

let test_query_contract () =
  let empty = Kll.create ~capacity:8 ~seed:0 () in
  check (Kll.minimum empty = None) "empty minimum is defined";
  check (Kll.maximum empty = None) "empty maximum is defined";
  check (Kll.quantile empty ~q:0.5 = None) "empty quantile is defined";
  check (Kll.rank empty 0.0 = None) "empty rank is defined";
  expect_invalid_argument (fun () -> Kll.quantile empty ~q:(-0.1));
  expect_invalid_argument (fun () -> Kll.quantile empty ~q:1.1);
  expect_invalid_argument (fun () -> Kll.quantile empty ~q:nan);
  expect_invalid_argument (fun () -> Kll.rank empty infinity);

  let ties = Kll.create ~capacity:16 ~seed:7 () in
  add_values ties [| -.Float.max_float; 2.0; 2.0; 2.0; Float.max_float |];
  check_float (-.Float.max_float)
    (get_some "minimum" (Kll.minimum ties))
    "exact minimum";
  check_float Float.max_float (get_some "maximum" (Kll.maximum ties))
    "exact maximum";
  check_float (-.Float.max_float)
    (get_some "q=0" (Kll.quantile ties ~q:0.0))
    "q=0";
  check_float Float.max_float
    (get_some "q=1" (Kll.quantile ties ~q:1.0))
    "q=1";
  check_float 2.0 (get_some "median" (Kll.quantile ties ~q:0.5))
    "duplicate median";
  check_float 0.8 (get_some "rank" (Kll.rank ties 2.0))
    "inclusive duplicate rank";
  check_invariants ties;

  let convention = make_range ~capacity:8 ~seed:3 0 5 in
  check_float 4.0
    (get_some "q=0.9" (Kll.quantile convention ~q:0.9))
    "zero-based lower quantile";
  let thirds = make_range ~capacity:8 ~seed:3 0 3 in
  check_float 0.0
    (get_some "q=1/3" (Kll.quantile thirds ~q:(1.0 /. 3.0)))
    "exact binary64 quantile target"

let test_seed_determinism () =
  let left = make_range ~capacity:24 ~seed:41 0 999 in
  let right = make_range ~capacity:24 ~seed:41 0 999 in
  check (Kll.retained left = Kll.retained right)
    "same seed changed retained count";
  List.iter
    (fun q ->
      check_float
        (get_some "left quantile" (Kll.quantile left ~q))
        (get_some "right quantile" (Kll.quantile right ~q))
        "same-seed quantile")
    [ 0.01; 0.1; 0.25; 0.5; 0.75; 0.9; 0.99 ]

let test_merge () =
  let left = make_range ~capacity:32 ~seed:11 0 499 in
  let right = make_range ~capacity:32 ~seed:29 500 999 in
  let left_retained = Kll.retained left in
  let right_retained = Kll.retained right in
  let merged =
    match Kll.merge ~seed:101 left right with
    | Ok sketch -> sketch
    | Error _ -> failwith "compatible KLL merge failed"
  in
  check (Kll.count left = 500L && Kll.retained left = left_retained)
    "merge changed its left input";
  check (Kll.count right = 500L && Kll.retained right = right_retained)
    "merge changed its right input";
  check (Kll.count merged = 1_000L) "merged count mismatch";
  check_float 0.0 (get_some "merged q=0" (Kll.quantile merged ~q:0.0))
    "merged minimum";
  check_float 999.0
    (get_some "merged q=1" (Kll.quantile merged ~q:1.0))
    "merged maximum";
  check_float 1.0 (get_some "rank(max)" (Kll.rank merged 999.0))
    "merged retained weight";
  check_invariants merged;
  let repeat =
    match Kll.merge ~seed:101 left right with
    | Ok sketch -> sketch
    | Error _ -> failwith "repeat KLL merge failed"
  in
  List.iter
    (fun q ->
      check_float
        (get_some "merged quantile" (Kll.quantile merged ~q))
        (get_some "repeat quantile" (Kll.quantile repeat ~q))
        "merge seed determinism")
    [ 0.1; 0.5; 0.9 ];
  let incompatible = Kll.create ~capacity:40 ~seed:0 () in
  match Kll.merge ~seed:3 left incompatible with
  | Error (`Incompatible_capacity (32, 40)) -> ()
  | _ -> failwith "incompatible KLL capacities were accepted"

let inclusive_rank sorted value =
  let rec upper_bound low high =
    if low = high then low
    else
      let middle = low + ((high - low) / 2) in
      if Float.compare sorted.(middle) value <= 0 then
        upper_bound (middle + 1) high
      else upper_bound low middle
  in
  Float.of_int (upper_bound 0 (Array.length sorted))
  /. Float.of_int (Array.length sorted)

let test_controlled_rank_characterization () =
  let n = 5_000 in
  let values = Array.init n (fun index -> Float.of_int ((index * 37) mod n)) in
  let sorted = Array.copy values in
  Array.sort Float.compare sorted;
  let largest_error = ref 0.0 in
  for seed = 0 to 15 do
    let sketch = Kll.create ~capacity:32 ~seed () in
    add_values sketch values;
    check_invariants sketch;
    List.iter
      (fun q ->
        let value = get_some "characterized quantile" (Kll.quantile sketch ~q) in
        let error = Float.abs (inclusive_rank sorted value -. q) in
        largest_error := Float.max !largest_error error)
      [ 0.01; 0.1; 0.25; 0.5; 0.75; 0.9; 0.99 ]
  done;
  (* This fixed corpus characterizes a regression, not a probabilistic bound.
     The loose limit catches lost weights without making ordinary sketch
     variation a CI failure. *)
  check (!largest_error <= 0.20)
    "controlled rank error %.6f exceeded the diagnostic limit" !largest_error

let singleton value =
  let sketch = Kll.create ~capacity:16 ~seed:0 () in
  expect_ok (Kll.add sketch value);
  sketch

let rec double ~value sketch remaining =
  if remaining = 0 then sketch
  else
    match Kll.merge ~seed:remaining sketch sketch with
    | Ok merged -> double ~value merged (remaining - 1)
    | Error _ -> failf "failed to double the %g sketch" value

let test_large_counts_and_overflow () =
  let zeros = double ~value:0.0 (singleton 0.0) 53 in
  let ones = double ~value:1.0 (singleton 1.0) 53 in
  let balanced =
    match Kll.merge ~seed:101 zeros ones with
    | Ok sketch -> sketch
    | Error _ -> failwith "large-count KLL merge failed"
  in
  check (Kll.count balanced = 18_014_398_509_481_984L)
    "large-count setup mismatch";
  check_float 0.0
    (get_some "large-count median" (Kll.quantile balanced ~q:0.5))
    "large-count lower median";
  check_invariants balanced;

  let rec fill_bits total power remaining =
    if remaining = 0 then total
    else
      let next_power =
        match Kll.merge ~seed:remaining power power with
        | Ok sketch -> sketch
        | Error _ -> failwith "count overflow reported while building a power"
      in
      let total =
        match Kll.merge ~seed:(100 + remaining) total next_power with
        | Ok sketch -> sketch
        | Error _ -> failwith "count overflow reported below Int64.max_int"
      in
      fill_bits total next_power (remaining - 1)
  in
  let one = singleton 1.0 in
  let full = fill_bits one one 62 in
  check (Kll.count full = Int64.max_int) "maximum KLL count setup failed";
  check_invariants full;
  let before =
    (Kll.count full, Kll.retained full, Kll.quantile full ~q:0.5)
  in
  (match Kll.add full 1.0 with
  | Error `Count_overflow -> ()
  | Error `Non_finite -> failwith "finite add reported non-finite input"
  | Ok () -> failwith "overflowing KLL add was accepted");
  check
    (before = (Kll.count full, Kll.retained full, Kll.quantile full ~q:0.5))
    "overflowing KLL add changed the sketch";
  match Kll.merge ~seed:0 full one with
  | Error `Count_overflow -> ()
  | Error (`Incompatible_capacity _) ->
      failwith "compatible KLL merge reported incompatible capacity"
  | Ok _ -> failwith "overflowing KLL merge was accepted"

let () =
  test_capacity_and_empty_state ();
  test_first_compaction_boundary ();
  test_weight_conservation_across_levels ();
  test_non_finite_rejection_is_atomic ();
  test_query_contract ();
  test_seed_determinism ();
  test_merge ();
  test_controlled_rank_characterization ();
  test_large_counts_and_overflow ()
