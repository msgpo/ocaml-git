(*
 * Copyright (c) 2013-2017 Thomas Gazagnaire <thomas@gazagnaire.org>
 * and Romain Calascibetta <romain.calascibetta@gmail.com>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

let () = Random.self_init ()
let () = Printexc.record_backtrace true

open Git_unix
module Sync = Git_unix.Sync (Store)
module Negociator = Git.Negociator.Make (Store)

module Log = struct
  let src = Logs.Src.create "main" ~doc:"logs binary event"

  include (val Logs.src_log src : Logs.LOG)
end

module Option = struct
  let map f = function Some v -> Some (f v) | None -> None
  let map_default v f = function Some v -> f v | None -> v
end

let pad n x =
  if String.length x > n then x else x ^ String.make (n - String.length x) ' '

let pp_header ppf (level, header) =
  let level_style =
    match level with
    | Logs.App -> Logs_fmt.app_style
    | Logs.Debug -> Logs_fmt.debug_style
    | Logs.Warning -> Logs_fmt.warn_style
    | Logs.Error -> Logs_fmt.err_style
    | Logs.Info -> Logs_fmt.info_style
  in
  let level = Logs.level_to_string (Some level) in
  Fmt.pf ppf "[%a][%a]"
    (Fmt.styled level_style Fmt.string)
    level (Fmt.option Fmt.string)
    (Option.map (pad 10) header)

let reporter ppf =
  let report src level ~over k msgf =
    let k _ = over () ; k () in
    let with_src_and_stamp h _ k fmt =
      let dt = Mtime.Span.to_us (Mtime_clock.elapsed ()) in
      Fmt.kpf k ppf
        ("%s %a %a: @[" ^^ fmt ^^ "@]@.")
        (pad 10 (Fmt.strf "%+04.0fus" dt))
        pp_header (level, h)
        Fmt.(styled `Magenta string)
        (pad 10 @@ Logs.Src.name src)
    in
    msgf @@ fun ?header ?tags fmt -> with_src_and_stamp header tags k fmt
  in
  {Logs.report}

let setup_logs style_renderer level ppf =
  Fmt_tty.setup_std_outputs ?style_renderer () ;
  Logs.set_level level ;
  Logs.set_reporter (reporter ppf) ;
  let quiet = match style_renderer with Some _ -> true | None -> false in
  quiet, ppf

type error = [`Store of Store.error | `Sync of Sync.error]

let store_err err = `Store err
let sync_err err = `Sync err

let pp_error ppf = function
  | `Store err -> Fmt.pf ppf "(`Store %a)" Store.pp_error err
  | `Sync err -> Fmt.pf ppf "(`Sync %a)" Sync.pp_error err

let main directory repository =
  let root = Option.map_default Fpath.(v (Sys.getcwd ())) Fpath.v directory in
  let ( >>?= ) = Lwt_result.bind in
  let ( >>!= ) v f = Lwt_result.map_err f v in
  Log.debug (fun l ->
      l "root:%a, repository:%a.\n" Fpath.pp root Uri.pp_hum repository ) ;
  Store.v root
  >>!= store_err
  >>?= fun git ->
  Sync.fetch_all git ~references:Store.Reference.Map.empty
    (endpoint repository)
  >>!= sync_err
  >>?= fun _ -> Lwt.return (Ok ())

open Cmdliner

module Flag = struct
  let output_value =
    let parse str =
      match str with
      | "stdout" -> Ok Fmt.stdout
      | "stderr" -> Ok Fmt.stderr
      | s -> Error (`Msg (Fmt.strf "%s is not an output." s))
    in
    let print ppf v =
      Fmt.pf ppf "%s" (if v == Fmt.stdout then "stdout" else "stderr")
    in
    Arg.conv ~docv:"<output>" (parse, print)

  let output =
    let doc = "Output of the progress status" in
    Arg.(
      value
      & opt output_value Fmt.stdout
      & info ["output"] ~doc ~docv:"<output>")

  let progress =
    let doc =
      "Progress status is reported on the standard error stream by default \
       when it is attached to a terminal, unless -q is specified. This flag \
       forces progress status even if the standard error stream is not \
       directed to a terminal."
    in
    Arg.(value & flag & info ["progress"] ~doc)

  let uri =
    let parse str = Ok (Uri.of_string str) in
    let print = Uri.pp_hum in
    Arg.conv ~docv:"<uri>" (parse, print)

  let repository =
    let doc = "" in
    Arg.(
      required
      & pos ~rev:true 0 (some uri) None
      & info [] ~docv:"<repository>" ~doc)

  let directory =
    let doc = "" in
    Arg.(
      value
      & pos ~rev:true 1 (some string) None
      & info [] ~doc ~docv:"<directory>")
end

let setup_log =
  Term.(
    const setup_logs
    $ Fmt_cli.style_renderer ()
    $ Logs_cli.level ()
    $ Flag.output)

let main _ directory repository _ =
  match Lwt_main.run (main directory repository) with
  | Ok () -> `Ok ()
  | Error (#error as err) -> `Error (false, Fmt.strf "%a" pp_error err)

let command =
  let doc = "Fetch a Git repository by the HTTP protocol." in
  let exits = Term.default_exits in
  ( Term.(
      ret
        ( const main
        $ Flag.progress
        $ Flag.directory
        $ Flag.repository
        $ setup_log ))
  , Term.info "ogit-http-fetch-all" ~version:"v0.1" ~doc ~exits )

let () = Term.(exit @@ eval command)
