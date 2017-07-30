open Amqp_thread
open Amqp_spec
open Amqp_lib

type no_confirm = [ `Ok ]
type with_confirm = [ `Ok | `Failed ]


type _ confirms =
  | No_confirm: no_confirm confirms
  | With_confirm: with_confirm confirms

let no_confirm = No_confirm
let with_confirm = With_confirm

type consumer = Basic.Deliver.t * Basic.Content.t * string -> unit
type consumers = (string, consumer) Hashtbl.t

type result = Delivered | Rejected | Undeliverable
type message_info = { delivery_tag: int;
                      routing_key: string;
                      exchange_name: string;
                      result_handler: result -> unit;
                    }

type publish_confirm = { mutable message_count: int;
                         unacked: message_info MList.t }

type _ pcp =
  | Pcp_no_confirm: no_confirm pcp
  | Pcp_with_confirm: publish_confirm -> with_confirm pcp

type return_writer = (Basic.Return.t * (Basic.Content.t * string)) Pipe.Writer.t

type 'a t = { framing: Amqp_framing.t;
              channel_no: int;
              consumers: consumers;
              id: string;
              mutable counter: int;
              publish_confirm: 'a pcp;
              mutable return_writers: return_writer list;
            }

let channel { framing; channel_no; _ } = (framing, channel_no)

module Internal = struct
  let next_counter t =
    t.counter <- t.counter + 1;
    t.counter

  let unique_id t =
    Printf.sprintf "%s.%d" t.id (next_counter t)

  let register_deliver_handler t =
    let open Basic in
    let handler (deliver, (content, data)) =
      try
        let handler = Hashtbl.find t.consumers deliver.Deliver.consumer_tag in
        handler (deliver, content, data);
        (* Keep the current handler *)
      with
      | Not_found -> failwith ("No consumers for: " ^ deliver.Deliver.consumer_tag)
    in
    let read = snd Deliver.Internal.read in
    read ~once:false handler (channel t)

  let register_consumer_handler t consumer_tag handler =
    if Hashtbl.mem t.consumers consumer_tag then raise Amqp_types.Busy;
    Hashtbl.add t.consumers consumer_tag handler

  let deregister_consumer_handler t consumer_tag =
    Hashtbl.remove t.consumers consumer_tag

  let set_result ivar = function
    | Delivered ->
      Printf.eprintf "Mark message as delivered\n%!";
      Ivar.fill ivar `Ok
    | Rejected ->
      Printf.eprintf "Mark message as rejected\n%!";
      Ivar.fill ivar `Failed
    | Undeliverable ->
      Printf.eprintf "Mark message as undeliverable\n%!";
      Ivar.fill ivar `Failed

  (** Need to add if we should expect returns also. *)
  let wait_for_confirm: type a. a t -> routing_key:string -> exchange_name:string -> a Deferred.t = fun t ~routing_key ~exchange_name ->
    match t.publish_confirm with
    | Pcp_with_confirm t ->
      let var = Ivar.create () in
      let result_handler = set_result var in
      t.message_count <- t.message_count + 1;
      let delivery_tag = t.message_count in
      MList.append t.unacked {delivery_tag; routing_key; exchange_name; result_handler};
      (Ivar.read var : [`Ok | `Failed] Deferred.t)
    | Pcp_no_confirm -> return `Ok
end

let close_handler channel_no close =
  Log.info "Channel closed: %d" channel_no;
  Log.info "Reply code: %d\n" close.Channel.Close.reply_code;
  Log.info "Reply text: %s\n" close.Channel.Close.reply_text;
  Log.info "Message: (%d, %d)\n" close.Channel.Close.class_id close.Channel.Close.method_id;
  raise (Amqp_types.Channel_closed channel_no)

let register_flow_handler t =
  let (_, read) = Channel.Flow.Internal.read in
  let handler { Channel.Flow.active } =
    Amqp_framing.set_flow t.framing t.channel_no active;
    spawn (Channel.Flow_ok.Internal.write (channel t) { Channel.Flow_ok.active })
  in
  read ~once:false handler (channel t)

let handle_confirms channel t =
  let confirm multiple result tag =
    Printf.eprintf "Received confirm\n%!";
    let results = match multiple with
      | true -> MList.take_while ~pred:(fun m -> m.delivery_tag <= tag) t.unacked
      | false -> MList.take ~pred:(fun m -> m.delivery_tag = tag) t.unacked
                 |> Option.map_default ~f:(fun v -> [v]) ~default:[]
    in
    List.iter (fun m -> m.result_handler result) results
  in

  let handle_return (r, _) =
    Printf.eprintf "Received return (undeliverable)\n%!";
    let pred message =
      message.routing_key = r.Basic.Return.routing_key && message.exchange_name = r.Basic.Return.exchange
    in

    match MList.take ~pred t.unacked with
    | None -> Printf.eprintf "No messages found to mark as undeliverable\n%!"
    | Some m -> m.result_handler Undeliverable
  in

  let open Basic in
  let read_ack = snd Ack.Internal.read in
  let read_reject = snd Reject.Internal.read in
  read_ack ~once:false (fun m -> confirm m.Ack.multiple Delivered m.Ack.delivery_tag) channel;
  read_reject ~once:false (fun m -> confirm false Rejected m.Reject.delivery_tag) channel;

  Confirm.Select.request channel { Confirm.Select.nowait = false } >>= fun () ->
  return handle_return

let register_return_handler t return_handler =
  Printf.eprintf "Register return handler\n%!";
  let handler message =
    Printf.eprintf "Distribute the returned message\n%!";
    List.iter (fun writer -> Pipe.write_without_pushback writer message ) t.return_writers
  in
  let handler = match return_handler with
    | Some return_handler -> fun m -> return_handler m; handler m
    | None -> handler
  in
  let (_, read) = Basic.Return.Internal.read in
  read ~once:false handler (channel t)

let create: type a. id:string -> a confirms -> Amqp_framing.t -> Amqp_framing.channel_no -> a t Deferred.t = fun ~id confirm_type framing channel_no ->
  let consumers = Hashtbl.create 0 in
  let id = Printf.sprintf "%s.%s.%d" (Amqp_framing.id framing) id channel_no in
  Amqp_framing.open_channel framing channel_no >>= fun () ->
  spawn (Channel.Close.reply (framing, channel_no) (close_handler channel_no));
  Channel.Open.request (framing, channel_no) () >>= fun () ->

  let publish_confirm : a pcp = match confirm_type with
    | With_confirm -> Pcp_with_confirm { message_count = 0; unacked = MList.create () }
    | No_confirm -> Pcp_no_confirm
  in
  begin match publish_confirm with
   | Pcp_with_confirm t -> handle_confirms (framing, channel_no) t >>= fun return_handler -> return (Some return_handler)
   | Pcp_no_confirm -> return None
  end >>= fun return_hander ->
  let t = { framing; channel_no; consumers; id; counter = 0; publish_confirm; return_writers = [] } in
  Internal.register_deliver_handler t;

  register_flow_handler t;
  register_return_handler t return_hander;
  return t

let close { framing; channel_no; return_writers; _ } =
  let open Channel.Close in
  request (framing, channel_no)
    { reply_code=200;
      reply_text="Closed on user request";
      class_id=0;
      method_id=0; } >>= fun () ->
  Amqp_framing.close_channel framing channel_no >>= fun () ->
  List.map Pipe.close return_writers |> Deferred.all_unit


let on_return t =
  let reader, writer = Pipe.create () in
  t.return_writers <- writer :: t.return_writers;
  reader

let flush t =
  Amqp_framing.flush_channel t.framing t.channel_no

let id t = t.id

let channel_no t = t.channel_no

let set_prefetch ?(count=0) ?(size=0) t =
  Basic.Qos.request (channel t) { Basic.Qos.prefetch_count=count;
                                  prefetch_size=size;
                                  global=false }

let set_global_prefetch ?(count=0) ?(size=0) t =
  Basic.Qos.request (channel t) { Basic.Qos.prefetch_count=count;
                                  prefetch_size=size;
                                  global=true }

module Transaction = struct
  type tx = EChannel: _ t -> tx

  open Amqp_spec.Tx
  let start t =
    Select.request (channel t) () >>= fun () ->
    return (EChannel t)

  let commit (EChannel t) =
    Commit.request (channel t) ()

  let rollback (EChannel t) =
    Rollback.request (channel t) ()
end
