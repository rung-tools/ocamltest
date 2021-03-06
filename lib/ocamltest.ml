(**
 * MIT License
 *
 * Copyright (c) 2018 NG Informática
 *
 * Written by:
 *
 * - Marcelo Camargo <marcelo.camargo@ngi.com.br>
 * - Paulo Torrens <paulotorrens@gnu.org>
 * - Paulo Henrique Cuchi <paulo.cuchi@ngi.com.br>
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 **)

open Core_extended

module C = Color_print

type file_system =
  | Dir of string * file_system list
  | File of string * string
  [@@deriving show]

type test = {
  flags: string;
  description: string;
  environment: string list;
  input: string;
  output: string;
  skip: bool
}
[@@deriving show]

type test_result =
  | Skipped
  | Passed of float
  | Failed of float

type parser_section =
  | Epsilon
  | Flags
  | Description
  | Environment
  | Input
  | Output

let get_test_info path =
  let initial_state =
    { flags = ""; description = ""; input = ""; output = ""; skip = false;
      environment = [] },
    Epsilon
  in
  let consume line prev_state section =
    let next_state =
      match section with
      | Flags -> { prev_state with flags = prev_state.flags ^ line }
      | Description ->
        { prev_state with description = prev_state.description ^ line }
      | Environment ->
        begin match String.length line with
        | 0 -> prev_state
        | _ -> { prev_state with environment = line :: prev_state.environment }
        end
      | Input -> { prev_state with input = prev_state.input ^ line ^ "\n" }
      | Output -> { prev_state with output = prev_state.output ^ line ^ "\n" }
      | Epsilon -> prev_state
    in
    (next_state, section)
  in
  Core.In_channel.read_lines path
  |> List.fold_left
    (fun (prev_state, section) line ->
      match line with
      | "[FLAGS]"       -> (prev_state, Flags)
      | "[DESCRIPTION]" -> (prev_state, Description)
      | "[ENVIRONMENT]" -> (prev_state, Environment)
      | "[INPUT]"       -> (prev_state, Input)
      | "[OUTPUT]"      -> (prev_state, Output)
      | "[SKIP]"        -> ({ prev_state with skip = true }, section)
      | line            -> consume line prev_state section)
    initial_state
  |> fst

let read_dir_test_files root =
  let rec loop name path =
    if Sys.is_directory path then
      let children = Sys.readdir path
      |> Array.to_list
      |> List.map (fun name -> loop name (Filename.concat path name))
      |> List.filter
        (function
        | Dir (_, [])    -> false
        | Dir _          -> true
        | File (name, _) -> Filename.check_suffix name ".mlt") in
      Dir (name, children)
    else
      File (name, path)
  in
  loop root root

let gen_fortune_cookie () =
  let niilist_messages = [|
    "A vida é um pato que se come frio";
    "Será que estamos vivendo ou apenas existindo?";
    "Não separa-se predicado por vírgula";
    "Sai do meu grupo";
    "Os testes passaram, mas minha vontade de morrer permanece";
    "Você deveria cobrar insalubridade por trabalhar com Clipper"
  |] in
  Random.self_init ();
  let index = Random.int (Array.length niilist_messages) in
  niilist_messages.(index)

let rec tree_size node =
  match node with
  | Dir (_, children) ->
    children
    |> List.fold_left (fun size node -> size + (tree_size node)) 0
  | File _ -> 1

let print_diff in_channel =
  Core.In_channel.iter_lines in_channel (fun line ->
    match Core.List.hd (Core.String.to_list line) with
    | None -> ()
    | Some '-' -> C.red_printf "%s\n" line;
    | Some '+' -> C.green_printf "%s\n" line;
    | Some '@' -> C.blue_printf "%s\n" line;
    | Some _   -> print_endline line)

let format_time millis =
  let format =
    if millis > 30.0 then C.yellow_sprintf else C.gray_sprintf ~brightness:0.4
  in
  format "(%.3fms)" millis

let indent level = String.make (4 * level) ' '

let print_test_status level result test_info =
  let passed_symbol = C.green "✓" in
  let failed_symbol = C.red "✗" in
  let skipped_symbol = C.cyan "●" in
  let print = Printf.printf "%s%s %s %s\n" (indent level) in
  match result with
  | Passed ms -> print passed_symbol test_info.description @@ format_time ms
  | Failed ms -> print failed_symbol test_info.description @@ format_time ms
  | Skipped   -> print skipped_symbol
    (C.gray ~brightness:0.5 test_info.description)
    (C.cyan "(skipped)")

let report_diff test_info execution_result path =
  let (expected_name, expected_channel) =
    Filename.open_temp_file "expected" ".txt" in
  Core.Out_channel.output_string expected_channel test_info.output;
  Core.Out_channel.close expected_channel;
  let (actual_name, actual_channel) =
    Filename.open_temp_file "actual" ".txt" in
  Core.Out_channel.output_string actual_channel execution_result;
  Core.Out_channel.close actual_channel;
  let command = Printf.sprintf "diff -tuW 80 %s %s"
    (String.escaped expected_name) (String.escaped actual_name) in
  let in_channel = Unix.open_process_in command in
  print_diff in_channel;
  C.red_printf "\n\n[%s]\nThe tests have failed. %s\n"
    path "Everything is terrible.";
  ignore (Unix.close_process_in in_channel);
  exit 1

let report_unexppected_error process_status level test_info possible_error =
  let open Unix in
  match process_status with
  | WEXITED n ->
    (* Exit code not zero (i.e., an error occurred) *)
    print_test_status level (Failed 0.0) test_info;
    Printf.printf "\n\n%s" possible_error;
    C.red_printf "\n\nThe compiler has returned error code %d. %s\n"
      n "Everything is terrible.";
    exit 2
  | _ ->
    (* Signal caught... this is odd... *)
    C.red_printf "\n\nThe compiler was killed by a signal. %s\n"
      "What has happened?";
    exit 3

let run_test name path level total_skipped total_passing =
  let test_info = get_test_info path in
  if test_info.skip then begin
    incr total_skipped;
    print_test_status level Skipped test_info
  end else begin
    let (temp_name, temp_channel) = Filename.open_temp_file "test" ".txt" in
    Core.Out_channel.output_string temp_channel test_info.input;
    Core.Out_channel.close temp_channel;
    let start_time = Unix.gettimeofday () in
    let variables =
      test_info.environment
      |> List.map (Printf.sprintf "export %s;")
      |> String.concat " " in
    let command = Printf.sprintf
      "%scat %s | ../_build/default/bin/main.exe %s"
      variables temp_name test_info.flags in

    (* Execute the command... *)
    let (in_channel, out_channel, err_channel) =
      Unix.open_process_full command [||] in

    (* Read it's output until it's closed (by the compiler)... *)
    let execution_result = Core.In_channel.input_all in_channel in
    let possible_error = Core.In_channel.input_all err_channel in

    (* Now close the executable and check the exit code... *)
    let status =
      Unix.close_process_full (in_channel, out_channel, err_channel) in
    match status with
    | WEXITED 0 ->
      let finish_time = Unix.gettimeofday () in
      let total_millis = (finish_time -. start_time) *. 1000.0 in
      let success = (String.trim execution_result) =
        (String.trim test_info.output) in
      let result =
        if success then (Passed total_millis) else (Failed total_millis) in
      print_test_status level result test_info;
      if not success then
        report_diff test_info execution_result path
      else
        incr total_passing
    | _ as process_status ->
      report_unexppected_error process_status level test_info possible_error
  end

let run_tests tree =
  let total_passing = ref 0 in
  let total_skipped = ref 0 in
  let rec run ?(level = 1) node =
    let run_dir files =
      List.iter (run ~level:(level + 1)) @@ List.sort compare files
    in
    match node with
    | Dir ("./", children) ->
      let target_directory = Sys.getcwd ()
      |> C.underline
      |> C.gray ~brightness:1.0 in
      C.blue_printf "\n    Running on directory [%s] (%d tests)\n\n"
        target_directory (tree_size tree);
        run_dir children
    | Dir (name, children) ->
      Printf.printf "%s%s/\n" (indent level) (C.cyan name);
      run_dir children
    | File (name, path) ->
      run_test name path level total_skipped total_passing
  in

  (* Run all tests *)
  run tree;
  print_newline ();

  (* Show test cound after running. *)
  print_endline  "        ---------------------------------------------------";
  C.green_printf "         - %d passing tests\n" !total_passing;
  C.cyan_printf  "         - %d skipped tests\n" !total_skipped;
  print_endline  "        ---------------------------------------------------";

  (* If we haven't exited... show a reassuring message! *)
  print_newline ();
  C.color_printf ~color:`Pink "        %s" (gen_fortune_cookie ());
  print_newline ();
  print_newline ()
