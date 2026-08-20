open Streaming_statistics

let value_or_nan = Option.value ~default:Float.nan

let () =
  let stats =
    match Bundle.create ~exact_median:true () with
    | Ok stats -> stats
    | Error _ -> failwith "invalid statistics configuration"
  in
  List.iter
    (fun value ->
      match Bundle.add stats value with
      | Ok () -> ()
      | Error `Non_finite -> failwith "the example contains a non-finite value"
      | Error `Count_overflow -> failwith "observation count overflow")
    [ 101.2; 100.8; 101.6; 102.0; 100.4 ];
  let median =
    match Bundle.exact_median stats with
    | Bundle.Enabled value -> value_or_nan value
    | Bundle.Disabled -> assert false
  in
  Printf.printf "count: %Ld\n" (Bundle.count stats);
  Printf.printf "mean: %.4f\n" (value_or_nan (Bundle.mean stats));
  Printf.printf "population variance: %.4f\n"
    (value_or_nan (Bundle.population_variance stats));
  Printf.printf "median: %.4f\n" median
