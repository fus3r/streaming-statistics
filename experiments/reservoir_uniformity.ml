module R = Streaming_statistics.Reservoir

let population = 32
let capacity = 4
let trials = 50_000
let diagnostic_limit = 6.

let () =
  let hits = Array.make population 0 in
  for seed = 0 to trials - 1 do
    let reservoir =
      match R.create ~capacity ~seed with
      | Ok reservoir -> reservoir
      | Error (`Invalid_capacity _) -> assert false
    in
    for position = 0 to population - 1 do
      match R.add reservoir position with
      | Ok () -> ()
      | Error `Count_overflow -> assert false
    done;
    let sample = R.sample reservoir in
    if Array.length sample <> capacity then
      failwith "reservoir sample has the wrong size";
    Array.iter
      (fun position ->
        if position < 0 || position >= population then
          failwith "reservoir returned an unknown position";
        hits.(position) <- hits.(position) + 1)
      sample
  done;
  let probability = Float.of_int capacity /. Float.of_int population in
  let expected = Float.of_int trials *. probability in
  let standard_deviation =
    Float.sqrt (Float.of_int trials *. probability *. (1. -. probability))
  in
  let minimum_hits = ref max_int in
  let maximum_hits = ref min_int in
  let worst_position = ref 0 in
  let maximum_absolute_z = ref 0. in
  Array.iteri
    (fun position observed ->
      minimum_hits := Int.min !minimum_hits observed;
      maximum_hits := Int.max !maximum_hits observed;
      let absolute_z =
        Float.abs ((Float.of_int observed -. expected) /. standard_deviation)
      in
      if absolute_z > !maximum_absolute_z then (
        maximum_absolute_z := absolute_z;
        worst_position := position))
    hits;
  Printf.printf
    "population,capacity,trials,expected_hits,min_hits,max_hits,worst_position,\
     max_absolute_z,diagnostic_limit\n";
  Printf.printf "%d,%d,%d,%.6f,%d,%d,%d,%.6f,%.1f\n" population capacity
    trials expected !minimum_hits !maximum_hits !worst_position
    !maximum_absolute_z diagnostic_limit;
  if !maximum_absolute_z > diagnostic_limit then
    failwith "reservoir marginal frequency exceeded the diagnostic limit"
