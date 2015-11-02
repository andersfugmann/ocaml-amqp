open Async.Std
module Connection = Amqp_connection
module Channel = Amqp_channel

open Amqp_spec.Exchange

type _ exchange_type =
  | Direct: unit exchange_type
  | Fanout: unit exchange_type
  | Topic: string exchange_type
  | Header: Amqp_types.header list exchange_type


type 'a t = { name : string;
              exchange_type: 'a exchange_type }

(** Predefined Default exchange *)
let default    = { name=""; exchange_type = Direct }

(** Predefined Direct exchange *)
let amq_direct = { name = "amq.direct"; exchange_type = Direct }

(** Predefined Fanout exchange *)
let amq_fanout = { name = "amq.fanout";  exchange_type = Fanout }

(** Predefined topic exchange *)
let amq_topic  = { name = "amq.topic"; exchange_type = Topic }

(** Predefined match (header) exchange *)
let amq_match = { name = "amq.match"; exchange_type = Header }

let string_of_exchange_type: type a. a exchange_type -> string  = function
  | Direct -> "direct"
  | Fanout -> "fanout"
  | Topic -> "topic"
  | Header -> "headers"

module Internal = struct
  let bind_queue: type a. _ Channel.t -> a t -> string -> a -> unit Deferred.t =
  let open Amqp_spec.Queue in
  fun channel { name; exchange_type} queue ->
    let query = { Bind.queue;
                  exchange = name;
                  routing_key = "";
                  no_wait = false;
                  arguments = [];
                }
    in
    match exchange_type with
    | Direct -> fun () -> Bind.request (Channel.channel channel) query
    | Fanout -> fun () -> Bind.request (Channel.channel channel) query
    | Topic -> fun routing_key -> Bind.request (Channel.channel channel) { query with Bind.routing_key }
    | Header -> fun arguments -> Bind.request (Channel.channel channel) { query with Bind.arguments }

  let unbind_queue: type a. _ Channel.t -> a t -> string -> a -> unit Deferred.t =
    let open Amqp_spec.Queue in
    fun channel { name; exchange_type} queue ->
      let query = { Unbind.queue;
                    exchange = name;
                    routing_key = "";
                    arguments = [];
                  }
      in
      match exchange_type with
      | Direct -> fun () -> Unbind.request (Channel.channel channel) query
      | Fanout -> fun () -> Unbind.request (Channel.channel channel) query
      | Topic -> fun routing_key -> Unbind.request (Channel.channel channel) { query with Unbind.routing_key }
      | Header -> fun arguments -> Unbind.request (Channel.channel channel) { query with Unbind.arguments }

end


let declare: type a. ?passive:bool -> ?durable:bool -> ?auto_delete:bool -> _ Channel.t -> a exchange_type -> string -> a t Deferred.t =
  fun ?(passive=false) ?(durable=false) ?(auto_delete=false) channel exchange_type name ->
    Declare.request (Channel.channel channel)
      { Declare.exchange = name;
        amqp_type = (string_of_exchange_type exchange_type);
        passive;
        durable;
        auto_delete;
        internal = false;
        no_wait = false;
        arguments = [] } >>= fun () ->
    return { name; exchange_type }

let delete ?(if_unused=false) channel t =
  Delete.request (Channel.channel channel)
    { Delete.exchange = t.name;
      if_unused;
      no_wait = false;
    }

let bind: type a. _ Channel.t -> destination:_ t -> source:a t -> a -> unit Deferred.t=
  fun channel ~destination ~source ->
    let query = { Bind.destination = destination.name;
                  source = source.name;
                  routing_key = "";
                  no_wait = false;
                  arguments = [];
                }
    in
    match source.exchange_type with
    | Direct -> fun () -> Bind.request (Channel.channel channel) query
    | Fanout -> fun () -> Bind.request (Channel.channel channel) query
    | Topic -> fun routing_key -> Bind.request (Channel.channel channel) { query with Bind.routing_key }
    | Header -> fun arguments -> Bind.request (Channel.channel channel) { query with Bind.arguments }

let unbind: type a. _ Channel.t -> destination:_ t -> source:a t -> a -> unit Deferred.t =
  fun channel ~destination ~source ->
  let query = { Unbind.destination = destination.name;
                source = source.name;
                routing_key = "";
                no_wait = false;
                arguments = [];
              }
  in
  match source.exchange_type with
    | Direct -> fun () -> Unbind.request (Channel.channel channel) query
    | Fanout -> fun () -> Unbind.request (Channel.channel channel) query
    | Topic -> fun routing_key -> Unbind.request (Channel.channel channel) { query with Unbind.routing_key }
    | Header -> fun arguments -> Unbind.request (Channel.channel channel) { query with Unbind.arguments }

let publish channel t
    ?(mandatory=false)
    ~routing_key
    (header, body) =

  let open Amqp_spec.Basic in
  let header = match header.Content.app_id with
    | Some _ -> header
    | None -> { header with Content.app_id = Some (Amqp_channel.id channel) }
  in
  let wait_for_confirm = Channel.Internal.wait_for_confirm channel in
  Publish.request (Amqp_channel.channel channel)
    ({Publish.exchange = t.name;
      routing_key=routing_key;
      mandatory;
      immediate=false},
     header, body) >>= fun () -> wait_for_confirm

let name t = t.name
