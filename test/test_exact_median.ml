module M = Streaming_statistics.Exact_median

let check condition message = if not condition then failwith message

let expect_ok = function
  | Ok () -> ()
  | Error `Non_finite -> failwith "unexpected non-finite input"

let sorted_median values =
  match List.sort Float.compare values with
  | [] -> None
  | sorted ->
      let size = List.length sorted in
      if size mod 2 = 1 then Some (List.nth sorted (size / 2))
      else
        let lower = List.nth sorted ((size / 2) - 1) in
        let upper = List.nth sorted (size / 2) in
        Some ((lower +. upper) /. 2.)

let check_value expected observed message =
  match (expected, observed) with
  | None, None -> ()
  | Some expected, Some observed when Float.compare expected observed = 0 -> ()
  | _ -> failwith message

let test_every_prefix_against_sort () =
  let state = M.create () in
  check (M.count state = 0L) "new median should have count zero";
  check_value None (M.value state) "empty median should be undefined";
  let seen = ref [] in
  let values =
    [ 5.; 2.; 10.; 4.; 4.; -3.; 8.; 0.; -0.; 11.; 1. ]
    @ List.init 257 (fun index ->
          Float.of_int (((index * 73) mod 101) - 50))
  in
  List.iter
    (fun value ->
      expect_ok (M.add state value);
      seen := value :: !seen;
      check
        (M.count state = Int64.of_int (List.length !seen))
        "median count disagrees with inserted values";
      check_value
        (sorted_median !seen)
        (M.value state)
        "two-heap median disagrees with sorted prefix")
    values

let test_even_midpoint_at_binary64_extremes () =
  let same_sign = M.create () in
  expect_ok (M.add same_sign Float.max_float);
  expect_ok (M.add same_sign Float.max_float);
  check_value (Some Float.max_float) (M.value same_sign)
    "median overflowed for two maximum floats";
  let opposite_signs = M.create () in
  expect_ok (M.add opposite_signs (-.Float.max_float));
  expect_ok (M.add opposite_signs Float.max_float);
  check_value (Some 0.) (M.value opposite_signs)
    "median overflowed across opposite signs";
  let subnormal = Int64.float_of_bits 1L in
  let equal_subnormals = M.create () in
  expect_ok (M.add equal_subnormals subnormal);
  expect_ok (M.add equal_subnormals subnormal);
  check_value (Some subnormal) (M.value equal_subnormals)
    "median underflowed for equal subnormal values";
  let next_subnormal = Int64.float_of_bits 2L in
  let adjacent = M.create () in
  expect_ok (M.add adjacent subnormal);
  expect_ok (M.add adjacent next_subnormal);
  check_value (Some next_subnormal) (M.value adjacent)
    "median rounded adjacent subnormal values incorrectly";
  let mixed_sign = M.create () in
  expect_ok (M.add mixed_sign (-.subnormal));
  expect_ok (M.add mixed_sign next_subnormal);
  check_value (Some 0.) (M.value mixed_sign)
    "median rounded mixed-sign subnormal values incorrectly"

let test_rejection_is_transactional () =
  let state = M.create () in
  expect_ok (M.add state 7.);
  let before = (M.count state, M.value state) in
  List.iter
    (fun value ->
      match M.add state value with
      | Error `Non_finite ->
          check
            (before = (M.count state, M.value state))
            "rejected value changed the median"
      | Ok () -> failwith "median accepted a non-finite value")
    [ Float.nan; Float.infinity; Float.neg_infinity ]

let () =
  test_every_prefix_against_sort ();
  test_even_midpoint_at_binary64_extremes ();
  test_rejection_is_transactional ()
