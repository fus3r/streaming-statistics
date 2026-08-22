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
              failf "%s:%d: non-finite input" path line_number;
            loop (line_number + 1) (value :: values)
      in
      loop 1 [])

let read_pairs path =
  In_channel.with_open_text path (fun input ->
      let rec loop line_number pairs =
        match In_channel.input_line input with
        | None -> Array.of_list (List.rev pairs)
        | Some line -> (
            match String.split_on_char ',' line with
            | [ x; y ] ->
                let parse name value =
                  try Float.of_string value
                  with Failure _ ->
                    failf "%s:%d: expected finite %s value" path line_number
                      name
                in
                let x = parse "x" x in
                let y = parse "y" y in
                if not (Float.is_finite x && Float.is_finite y) then
                  failf "%s:%d: non-finite pair" path line_number;
                loop (line_number + 1) ((x, y) :: pairs)
            | _ -> failf "%s:%d: expected x,y" path line_number)
      in
      loop 1 [])

let add_summary summary value =
  match Summary.add summary value with
  | Ok () -> ()
  | Error `Non_finite -> assert false
  | Error `Count_overflow -> failwith "summary count overflow"

let merge_summary left right =
  match Summary.merge left right with
  | Ok summary -> summary
  | Error `Count_overflow -> failwith "summary merge count overflow"

let add_bivariate summary (x, y) =
  match Bivariate.add summary x y with
  | Ok () -> ()
  | Error `Non_finite -> assert false
  | Error `Count_overflow -> failwith "bivariate count overflow"

let merge_bivariate left right =
  match Bivariate.merge left right with
  | Ok summary -> summary
  | Error `Count_overflow -> failwith "bivariate merge count overflow"

let summarize_slice values start length =
  let summary = Summary.create () in
  for index = start to start + length - 1 do
    add_summary summary values.(index)
  done;
  summary

let chunk_summaries values chunk_size =
  let rec loop start chunks =
    if start >= Array.length values then List.rev chunks
    else
      let length = Int.min chunk_size (Array.length values - start) in
      loop (start + length) (summarize_slice values start length :: chunks)
  in
  loop 0 []

let summarize_pair_slice pairs start length =
  let summary = Bivariate.create () in
  for index = start to start + length - 1 do
    add_bivariate summary pairs.(index)
  done;
  summary

let pair_chunk_summaries pairs chunk_size =
  let rec loop start chunks =
    if start >= Array.length pairs then List.rev chunks
    else
      let length = Int.min chunk_size (Array.length pairs - start) in
      loop (start + length) (summarize_pair_slice pairs start length :: chunks)
  in
  loop 0 []

let merge_left ~empty ~merge = function
  | [] -> empty ()
  | first :: rest -> List.fold_left merge first rest

let rec merge_balanced ~empty ~merge = function
  | [] -> empty ()
  | [ summary ] -> summary
  | summaries ->
      let rec pair values output =
        match values with
        | left :: right :: rest -> pair rest (merge left right :: output)
        | [ last ] -> List.rev (last :: output)
        | [] -> List.rev output
      in
      merge_balanced ~empty ~merge (pair summaries [])

let remove_nth index values =
  let rec loop current prefix = function
    | [] -> invalid_arg "remove_nth"
    | value :: rest ->
        if current = index then (value, List.rev_append prefix rest)
        else loop (current + 1) (value :: prefix) rest
  in
  loop 0 [] values

let merge_random ~empty ~merge ~seed summaries =
  let random = Random.State.make [| seed |] in
  let rec loop = function
    | [] -> empty ()
    | [ summary ] -> summary
    | values ->
        let left_index = Random.State.int random (List.length values) in
        let left, without_left = remove_nth left_index values in
        let right_index = Random.State.int random (List.length without_left) in
        let right, rest = remove_nth right_index without_left in
        loop (merge left right :: rest)
  in
  loop summaries

let option_float = function None -> Float.nan | Some value -> value

let print_estimate method_name count sum mean variance =
  Printf.printf "%s,%Ld,%.17g,%.17g,%.17g\n" method_name count sum mean
    variance

let run_stability path chunk_size seed =
  if chunk_size <= 0 then invalid_arg "chunk size must be positive";
  let values = read_values path in
  if Array.length values = 0 then invalid_arg "stability input is empty";
  let naive_sum = ref 0. in
  let naive_sum_sq = ref 0. in
  Array.iter
    (fun value ->
      naive_sum := !naive_sum +. value;
      naive_sum_sq := !naive_sum_sq +. (value *. value))
    values;
  let n = Float.of_int (Array.length values) in
  let naive_mean = !naive_sum /. n in
  let naive_variance = (!naive_sum_sq /. n) -. (naive_mean *. naive_mean) in
  let sequential = summarize_slice values 0 (Array.length values) in
  let chunks = chunk_summaries values chunk_size in
  let estimates =
    [
      ("welford", sequential);
      ("chan_left", merge_left ~empty:Summary.create ~merge:merge_summary chunks);
      ( "chan_balanced",
        merge_balanced ~empty:Summary.create ~merge:merge_summary chunks );
      ( "chan_random",
        merge_random ~empty:Summary.create ~merge:merge_summary ~seed chunks );
    ]
  in
  print_endline "method,count,sum,mean,population_variance";
  print_estimate "naive" (Int64.of_int (Array.length values)) !naive_sum
    naive_mean naive_variance;
  List.iter
    (fun (name, summary) ->
      print_estimate name (Summary.count summary) (Summary.sum summary)
        (option_float (Summary.mean summary))
        (option_float (Summary.population_variance summary)))
    estimates

let bivariate_estimates summary =
  let covariance = option_float (Bivariate.population_covariance summary) in
  let correlation = option_float (Bivariate.correlation summary) in
  let slope, intercept =
    match Bivariate.linear_regression summary with
    | None -> (Float.nan, Float.nan)
    | Some { slope; intercept } -> (slope, intercept)
  in
  (covariance, correlation, slope, intercept)

let print_bivariate_estimate method_name summary =
  let covariance, correlation, slope, intercept = bivariate_estimates summary in
  Printf.printf "%s,%Ld,%.17g,%.17g,%.17g,%.17g\n" method_name
    (Bivariate.count summary) covariance correlation slope intercept

let run_bivariate_stability path chunk_size seed =
  if chunk_size <= 0 then invalid_arg "chunk size must be positive";
  let pairs = read_pairs path in
  if Array.length pairs = 0 then invalid_arg "bivariate input is empty";
  let sequential = summarize_pair_slice pairs 0 (Array.length pairs) in
  let chunks = pair_chunk_summaries pairs chunk_size in
  let estimates =
    [
      ("welford", sequential);
      ( "chan_left",
        merge_left ~empty:Bivariate.create ~merge:merge_bivariate chunks );
      ( "chan_balanced",
        merge_balanced ~empty:Bivariate.create ~merge:merge_bivariate chunks );
      ( "chan_random",
        merge_random ~empty:Bivariate.create ~merge:merge_bivariate ~seed chunks );
    ]
  in
  print_endline
    "method,count,population_covariance,correlation,slope,intercept";
  List.iter
    (fun (name, summary) -> print_bivariate_estimate name summary)
    estimates

let usage () =
  prerr_endline
    "usage:\n\
    \  experiment_driver stability INPUT CHUNK_SIZE MERGE_SEED\n\
    \  experiment_driver bivariate-stability INPUT CHUNK_SIZE MERGE_SEED";
  exit 2

let int_arg name value =
  try int_of_string value with Failure _ -> failf "invalid %s: %s" name value

let () =
  match Array.to_list Sys.argv with
  | [ _; "stability"; path; chunk_size; seed ] ->
      run_stability path (int_arg "chunk size" chunk_size)
        (int_arg "merge seed" seed)
  | [ _; "bivariate-stability"; path; chunk_size; seed ] ->
      run_bivariate_stability path (int_arg "chunk size" chunk_size)
        (int_arg "merge seed" seed)
  | _ -> usage ()
