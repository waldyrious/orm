(*
 * Copyright (c) 2009 Anil Madhavapeddy <anil@recoil.org>
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

open Sqlite3
open Printf

let debug env ty n e = 
  let in_env s = List.exists (function | `Debug sl -> List.mem s sl | _ -> false)  env in
  let d () = prerr_endline (n ^ ": " ^ e) in
  let b () = () in
  if (match ty with
		  |`Sql -> in_env "sql" || in_env "all"
		  |`Cache -> in_env "cache" || in_env "all"
		  |`Bind -> in_env "binds" || in_env "all"
	 ) then d() else b()

type transaction_mode = [
    |`Deferred
    |`Immediate
    |`Exclusive
]

type 'a state = {
    db : db;
    mutable in_transaction: int;
    busyfn: db -> unit;
    mode: transaction_mode;
    cache: 'a;
}

let default_busyfn (db:Sqlite3.db) =
    print_endline "WARNING: busy";
    Unix.sleep 1

let new_state cache name =
    { db=db_open name; in_transaction=0; busyfn=default_busyfn; mode=`Deferred; cache=cache }

let raise_sql_error x =
    raise (Sqlite3.Error (Rc.to_string x))

let try_finally fn finalfn =
    try
      let r = fn () in
      finalfn ();
      r
    with e -> begin
      print_endline (sprintf "WARNING: exception: %s" (Printexc.to_string e));
      finalfn ();
      raise e
    end

(* retry until a non-BUSY error code is returned *)
let rec db_busy_retry db fn =
    match fn () with
    |Rc.BUSY -> 
       db.busyfn db.db;
       db_busy_retry db fn;
    |x -> x

(* make sure an OK is returned from the database *)
let db_must_ok db fn =
    match db_busy_retry db fn with
    |Rc.OK -> ()
    |x -> raise_sql_error x

(* make sure a DONE is returned from the database *)
let db_must_done db fn = 
   match db_busy_retry db fn with
   |Rc.DONE -> ()
   |x -> raise_sql_error x

let db_must_bind db stmt pos data =
   db_must_ok db (fun () -> Sqlite3.bind stmt pos data)

let db_must_reset db stmt =
   db_must_ok db (fun () -> Sqlite3.reset stmt)

let db_must_step db stmt =
   db_must_done db (fun () -> Sqlite3.step stmt)

(* request a transaction *)
let transaction db fn =
    let m = match db.mode with
    |`Deferred -> "DEFERRED" |`Immediate -> "IMMEDIATE" |`Exclusive -> "EXCLUSIVE" in
    try_finally (fun () ->
        if db.in_transaction = 0 then (
           db_must_ok db (fun () -> exec db.db (sprintf "BEGIN %s TRANSACTION" m));
        );
        db.in_transaction <- db.in_transaction + 1;
        fn ();
    ) (fun () ->
        if db.in_transaction = 1 then (
           db_must_ok db (fun () -> exec db.db "END TRANSACTION");
        );
        db.in_transaction <- db.in_transaction - 1
    )

(* iterate over a result set *)
let step_map db stmt iterfn =
    let stepfn () = Sqlite3.step stmt in
    let rec fn a = match db_busy_retry db stepfn with
    |Sqlite3.Rc.ROW -> fn (iterfn stmt :: a)
    |Sqlite3.Rc.DONE -> a
    |x -> raise_sql_error x
    in
    fn []

(* iterate over a result set and return an array *)
let step_map_array db stmt iterfn =
  Array.of_list (step_map db stmt iterfn)

(* List version of Array.iteri *)
let list_iteri fn =
  let p = ref 0 in
  List.iter (fun x ->
    fn !p x;
    incr p
  ) 