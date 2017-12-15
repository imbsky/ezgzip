open Astring
open Rresult

type error =
  | Invalid_format
  | Compression_error of string
  | Size of {got: int; expected: int}
  | Checksum

let pp_error fmt error =
  match error with
  | Invalid_format -> Format.fprintf fmt "Invalid gzip format"
  | Compression_error msg -> Format.fprintf fmt "Compression error: %s" msg
  | Size {got; expected} ->
      Format.fprintf fmt
        "Size mismatch after decompression: got %d, expected %d" got expected
  | Checksum -> Format.fprintf fmt "Invalid checksum after decompression"


let pp_gzip_error fmt wrapped =
  let `Gzip error = wrapped in
  pp_error fmt error


let error e = R.error (`Gzip e)

let id1_id2 = "\031\139"

(* XXX: Hard-coded gzip header may not be the best idea... *)
let header =
  let compression_method = "\b" in
  let flags1 = "\000" in
  let time = "\000\000\000\000" in
  let flags2 = "\000" in
  let os = "\255" in
  String.concat [id1_id2; compression_method; flags1; time; flags2; os]


let header_size =
  let bytes = String.length header in
  assert (bytes = 10) ;
  bytes


let footer_size = 8

let compress ?level raw =
  ( match level with
  | None -> ()
  | Some i ->
      if i < 0 || i > 9 then
        invalid_arg
          (strf "Ezgzip.compress: invalid level %d - must be between 0 and 9" i)
  ) ;
  let int32_to_bytestring i =
    let buf = Bytes.create 4 in
    EndianString.LittleEndian.set_int32 buf 0 i ;
    Bytes.to_string buf
  in
  let t = Cryptokit.Zlib.compress ?level () in
  let compressed = Cryptokit.transform_string t raw in
  let length = String.length raw in
  let crc32 = Crc.Crc32.string raw 0 length in
  let crc32_checksum = int32_to_bytestring crc32 in
  let original_size =
    int32_to_bytestring (Int32.of_int (length mod 0x1_0000_0000))
  in
  String.concat [header; compressed; crc32_checksum; original_size]


type t = {compressed: string; crc32: int32; original_size: int}

let parse_gzip_bytes raw =
  (* XXX: Ignoring most of the header may not be the best idea... *)
  let ( >>= ) = R.( >>= ) in
  (* Make sure we have enough bytes to work with *)
  ( if String.length raw < header_size + footer_size then error Invalid_format
  else Ok () )
  >>= fun () ->
  (* Check magic bytes *)
  (if String.is_prefix ~affix:id1_id2 raw then Ok () else error Invalid_format)
  >>= fun () ->
  (* Make sure we actually have data left over *)
  let compressed_length = String.length raw - header_size - footer_size in
  assert (compressed_length >= 0) ;
  let compressed =
    String.with_range ~first:header_size ~len:compressed_length raw
  in
  let crc32 =
    EndianString.LittleEndian.get_int32 raw (String.length raw - 4 - 4)
  in
  let original_size =
    let size =
      EndianString.LittleEndian.get_int32 raw (String.length raw - 4)
    in
    Int32.to_int size land 0xffff_ffff
  in
  Ok {compressed; crc32; original_size}


let decompress ?(ignore_size= false) ?(ignore_checksum= false) raw =
  let ( >>= ) = R.( >>= ) in
  parse_gzip_bytes raw
  >>= fun {compressed; crc32; original_size} ->
  (let t = Cryptokit.Zlib.uncompress () in
   match Cryptokit.transform_string t compressed with
   | uncompressed -> Ok uncompressed
   | exception Cryptokit.Error Compression_error (_function, msg) ->
       R.error (`Gzip (Compression_error msg)))
  >>= fun uncompressed ->
  if not ignore_size
     && String.length uncompressed mod 0x1_0000_0000 <> original_size
  then
    R.error
      (`Gzip (Size {got= String.length uncompressed; expected= original_size}))
  else
    let crc32_calculated () =
      Crc.Crc32.string uncompressed 0 (String.length uncompressed)
    in
    if not ignore_checksum && crc32_calculated () <> crc32 then
      R.error (`Gzip Checksum)
    else Ok uncompressed