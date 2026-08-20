open Streaming_statistics

let add_or_fail add state value =
  match add state value with
  | Ok () -> ()
  | Error `Non_finite -> failwith "the example contains a non-finite value"
  | Error `Count_overflow -> failwith "observation count overflow"

let value_or_nan = Option.value ~default:Float.nan

let () =
  let exact = Exact_median.create () in
  let sketch = Kll.create ~capacity:32 ~seed:2026 () in
  for value = 1 to 10_000 do
    let observation = Float.of_int value in
    add_or_fail Exact_median.add exact observation;
    add_or_fail Kll.add sketch observation
  done;
  Printf.printf "exact median: %.1f\n"
    (value_or_nan (Exact_median.value exact));
  List.iter
    (fun q ->
      Printf.printf "KLL q=%.2f: %.1f\n" q
        (value_or_nan (Kll.quantile sketch ~q)))
    [ 0.1; 0.5; 0.9; 0.99 ];
  Printf.printf "retained: %d of %Ld\n" (Kll.retained sketch)
    (Kll.count sketch)
