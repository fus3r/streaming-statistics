open Streaming_statistics

let failf format = Printf.ksprintf failwith format

let read_values path =
  In_channel.with_open_text path (fun input ->
      let rec loop line_number values =
        match In_channel.input_line input with
        | None -> Array.of_list (List.rev values)
        | Some line ->
            let value =
              try Float.of_string line
              with Failure _ ->
                failf "%s:%d: expected one float per line" path line_number
            in
            if not (Float.is_finite value) then
              failf "%s:%d: expected a finite value" path line_number;
            loop (line_number + 1) (value :: values)
      in
      loop 1 [])

let add summary value =
  match Summary.add summary value with
  | Ok () -> ()
  | Error `Non_finite -> assert false
  | Error `Count_overflow -> failwith "summary count overflow"

let summarize_slice values start length =
  let summary = Summary.create () in
  for index = start to start + length - 1 do
    add summary values.(index)
  done;
  summary

let chunk_summaries values =
  let chunk_size = 3 in
  let rec loop start chunks =
    if start >= Array.length values then List.rev chunks
    else
      let length = Int.min chunk_size (Array.length values - start) in
      loop (start + length) (summarize_slice values start length :: chunks)
  in
  loop 0 []

let merge left right =
  match Summary.merge left right with
  | Ok summary -> summary
  | Error `Count_overflow -> failwith "summary merge count overflow"

let value name = function
  | Some value -> value
  | None -> failf "%s is undefined" name

let print_row method_name count sum mean variance =
  Printf.printf "%s,%Ld,%.17g,%.17g,%.17g\n" method_name count sum mean
    variance

let () =
  if Array.length Sys.argv <> 2 then
    failwith "usage: summary_stability DATA";
  let values = read_values Sys.argv.(1) in
  if Array.length values = 0 then failwith "stability corpus is empty";
  let sequential = summarize_slice values 0 (Array.length values) in
  let partitioned =
    match chunk_summaries values with
    | [] -> assert false
    | first :: rest -> List.fold_left merge first rest
  in
  let naive_sum, naive_sum_sq =
    Array.fold_left
      (fun (sum, sum_sq) x -> (sum +. x, sum_sq +. (x *. x)))
      (0., 0.) values
  in
  let count = Int64.of_int (Array.length values) in
  let divisor = Int64.to_float count in
  let naive_mean = naive_sum /. divisor in
  let naive_variance =
    (naive_sum_sq /. divisor) -. (naive_mean *. naive_mean)
  in
  print_endline "method,count,sum,mean,population_variance";
  print_row "naive" count naive_sum naive_mean naive_variance;
  print_row "welford" (Summary.count sequential) (Summary.sum sequential)
    (value "Welford mean" (Summary.mean sequential))
    (value "Welford variance" (Summary.population_variance sequential));
  print_row "chan" (Summary.count partitioned) (Summary.sum partitioned)
    (value "Chan mean" (Summary.mean partitioned))
    (value "Chan variance" (Summary.population_variance partitioned))
