module Kll = Streaming_statistics.Kll

let failf format = Printf.ksprintf failwith format

let check condition format =
  Printf.ksprintf (fun message -> if not condition then failwith message) format

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

let () =
  test_capacity_and_empty_state ();
  test_first_compaction_boundary ();
  test_weight_conservation_across_levels ();
  test_non_finite_rejection_is_atomic ()
