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

let add_median median value =
  match Exact_median.add median value with
  | Ok () -> ()
  | Error `Non_finite -> assert false

let add_kll sketch value =
  match Kll.add sketch value with
  | Ok () -> ()
  | Error `Non_finite -> assert false
  | Error `Count_overflow -> failwith "KLL count overflow"

let exact_median values =
  let median = Exact_median.create () in
  Array.iter (add_median median) values;
  median

let sequential_kll values capacity seed =
  let sketch = Kll.create ~capacity ~seed () in
  Array.iter (add_kll sketch) values;
  sketch

let merged_kll values capacity partition_seed partition_size merge_seed =
  if partition_size <= 0 then invalid_arg "partition size must be positive";
  let partition_rng = Random.State.make [| partition_seed |] in
  let rec chunks start output =
    if start >= Array.length values then List.rev output
    else
      let length = Int.min partition_size (Array.length values - start) in
      let seed = Random.State.bits partition_rng in
      let sketch = Kll.create ~capacity ~seed () in
      for index = start to start + length - 1 do
        add_kll sketch values.(index)
      done;
      chunks (start + length) (sketch :: output)
  in
  let merge_rng = Random.State.make [| merge_seed |] in
  let merge left right =
    match Kll.merge ~seed:(Random.State.bits merge_rng) left right with
    | Ok sketch -> sketch
    | Error (`Incompatible_capacity _) -> assert false
    | Error `Count_overflow -> failwith "KLL merge count overflow"
  in
  merge_balanced
    ~empty:(fun () -> Kll.create ~capacity ~seed:partition_seed ())
    ~merge (chunks 0 [])

let print_quantiles ~construction ?partition_size ?merge_seed median sketch
    quantiles =
  let optional_int = function None -> "" | Some value -> string_of_int value in
  Printf.printf
    "kind,construction,partition_size,merge_seed,q,value,count,retained\n";
  Printf.printf "exact_median,exact,,,0.5,%.17g,%Ld,%Ld\n"
    (option_float (Exact_median.value median))
    (Exact_median.count median) (Exact_median.count median);
  List.iter
    (fun q ->
      Printf.printf "kll,%s,%s,%s,%.17g,%.17g,%Ld,%d\n" construction
        (optional_int partition_size) (optional_int merge_seed) q
        (option_float (Kll.quantile sketch ~q))
        (Kll.count sketch) (Kll.retained sketch))
    quantiles

let check_kll sketch =
  match Kll.check_invariants sketch with
  | Ok () -> ()
  | Error message -> failf "KLL invariant failure: %s" message

let run_quantiles path capacity seed quantiles =
  let values = read_values path in
  if Array.length values = 0 then invalid_arg "quantile input is empty";
  let median = exact_median values in
  let sketch = sequential_kll values capacity seed in
  check_kll sketch;
  print_quantiles ~construction:"sequential" median sketch quantiles

let run_merged_quantiles path capacity partition_seed partition_size merge_seed
    quantiles =
  let values = read_values path in
  if Array.length values = 0 then invalid_arg "quantile input is empty";
  let median = exact_median values in
  let sketch =
    merged_kll values capacity partition_seed partition_size merge_seed
  in
  check_kll sketch;
  print_quantiles ~construction:"balanced_merge" ~partition_size ~merge_seed
    median sketch quantiles

let usage () =
  prerr_endline
    "usage:\n\
    \  experiment_driver stability INPUT CHUNK_SIZE MERGE_SEED\n\
    \  experiment_driver bivariate-stability INPUT CHUNK_SIZE MERGE_SEED\n\
    \  experiment_driver quantiles INPUT CAPACITY SEED Q [Q ...]\n\
    \  experiment_driver quantiles-merged INPUT CAPACITY PARTITION_SEED \
     PARTITION_SIZE MERGE_SEED Q [Q ...]";
  exit 2

let int_arg name value =
  try int_of_string value with Failure _ -> failf "invalid %s: %s" name value

let float_arg name value =
  try Float.of_string value with Failure _ -> failf "invalid %s: %s" name value

let () =
  match Array.to_list Sys.argv with
  | [ _; "stability"; path; chunk_size; seed ] ->
      run_stability path (int_arg "chunk size" chunk_size)
        (int_arg "merge seed" seed)
  | [ _; "bivariate-stability"; path; chunk_size; seed ] ->
      run_bivariate_stability path (int_arg "chunk size" chunk_size)
        (int_arg "merge seed" seed)
  | _ :: "quantiles" :: path :: capacity :: seed :: quantiles
    when quantiles <> [] ->
      run_quantiles path (int_arg "capacity" capacity) (int_arg "seed" seed)
        (List.map (float_arg "quantile") quantiles)
  | _ :: "quantiles-merged" :: path :: capacity :: partition_seed
    :: partition_size :: merge_seed :: quantiles
    when quantiles <> [] ->
      run_merged_quantiles path (int_arg "capacity" capacity)
        (int_arg "partition seed" partition_seed)
        (int_arg "partition size" partition_size)
        (int_arg "merge seed" merge_seed)
        (List.map (float_arg "quantile") quantiles)
  | _ -> usage ()
