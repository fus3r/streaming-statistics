module R = Streaming_statistics.Reservoir

let check condition message = if not condition then failwith message

let expect_ok = function
  | Ok () -> ()
  | Error `Count_overflow -> failwith "unexpected reservoir count overflow"

let make ~capacity ~seed =
  match R.create ~capacity ~seed with
  | Ok state -> state
  | Error (`Invalid_capacity invalid) ->
      failwith (Printf.sprintf "unexpected invalid capacity: %d" invalid)

let algorithm_r_reference ~capacity ~seed values =
  let random = Random.State.make [| seed |] in
  let slots = Array.make capacity None in
  List.iteri
    (fun offset value ->
      let seen = offset + 1 in
      if offset < capacity then slots.(offset) <- Some value
      else
        let index = Random.State.int64 random (Int64.of_int seen) in
        if Int64.compare index (Int64.of_int capacity) < 0 then
          slots.(Int64.to_int index) <- Some value)
    values;
  Array.map (function Some value -> value | None -> assert false) slots

let test_algorithm_r_and_count () =
  let capacity = 7 in
  let seed = 20260816 in
  let values = List.init 200 (fun index -> "item-" ^ string_of_int index) in
  let state = make ~capacity ~seed in
  List.iter (fun value -> expect_ok (R.add state value)) values;
  check (R.capacity state = capacity) "reservoir capacity changed";
  check (R.count state = 200L) "reservoir count is wrong";
  check
    (R.sample state = algorithm_r_reference ~capacity ~seed values)
    "reservoir differs from Algorithm R"

let test_initial_fill () =
  let state = make ~capacity:5 ~seed:9 in
  check (R.count state = 0L) "new reservoir should have count zero";
  check (R.sample state = [||]) "new reservoir should have an empty sample";
  List.iter (fun value -> expect_ok (R.add state value)) [ 3; 1; 4 ];
  check (R.count state = 3L) "initial fill count is wrong";
  check (R.sample state = [| 3; 1; 4 |])
    "initial fill should retain every observation"

let test_seed_reproducibility_and_snapshot () =
  let first = make ~capacity:4 ~seed:42 in
  let second = make ~capacity:4 ~seed:42 in
  List.iter
    (fun value ->
      expect_ok (R.add first value);
      expect_ok (R.add second value))
    (List.init 50 Fun.id);
  check (R.sample first = R.sample second)
    "equal seeds and streams should reproduce";
  let snapshot = R.sample first in
  snapshot.(0) <- -1;
  check ((R.sample first).(0) <> -1)
    "sample should not expose mutable reservoir slots"

let test_zero_capacity () =
  match R.create ~capacity:0 ~seed:9 with
  | Error (`Invalid_capacity 0) -> ()
  | Error (`Invalid_capacity invalid) ->
      failwith (Printf.sprintf "wrong invalid capacity: %d" invalid)
  | Ok _ -> failwith "zero reservoir capacity was accepted"

let () =
  test_algorithm_r_and_count ();
  test_initial_fill ();
  test_seed_reproducibility_and_snapshot ();
  test_zero_capacity ()
