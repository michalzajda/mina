## Summary
[summary]: #summary

We can version serializations used in Mina, besides `Bin_prot` serializations, by
extending the existing versioning mechanism.

## Motivation
[motivation]: #motivation

Some of the data persisted by Mina nodes will change structure from
time-to-time.  For example, the structure of "precomputed blocks" will
change at the hard fork.  We wish to have a mechanism to distinguish
different versions of such structures, and allow using older versions
in current code.

## Detailed design
[detailed-design]: #detailed-design

### Top-tagged JSON

In RFC 0047, there is a suggestion to allow "top-tagging" of
`Bin_prot` serializations.  For JSON serializations, that approach can
be the default. In a versioned module `Vn`, we would shadow the
generated Yojson functions:
```ocaml
  let to_yojson item = `Assoc [("version",`Int n)
                              ;("data",to_yojson item)
							  ]

  let of_yojson json =
	match json with
	| `Assoc [("version",`Int version)
             ;("data",data_json)
             ] ->
       if version = n then
		   of_yojson data_json
	   else
		   Error (sprintf "In JSON, expected version %d, got %d" n version)
    | _	-> Error "Expected versioned JSON"
```

For `Bin_prot`-serialized data, we already generate:
```ocaml
  val bin_read_to_latest_opt : Bin_prot.Common.buf -> pos_ref:(int ref) -> Stable.Latest.t option
```
which allows reading serialized data of any version, and converting to
the latest version. (RFC 0047 proposes generating that function in a
slightly different way.)

For JSON, we can have:
```ocaml
  val of_yojson_to_latest_opt : Yojson.Safe.t -> Stable.Latest.t Or_error.t
```
The returned value can indicate an error when the JSON has an invalid version,
is missing a version field, or is otherwise ill-formatted.

We wish to generated top-tagged JSON only for selected types. In the usual case,
we do not shadow the functions generated by `deriving yojson`. When we do
want top-tagging, in the `Stable` module, we can add the annotation:
```
  [@@@version_tag_yojson]
```

### Top-tagged S-expressions

If needed, we could follow an approach to version-tag S-expressions similar to the one
proposed here for JSON.

### Legacy precomputed blocks

There is a cache of precomputed blocks stored in Google Cloud in JSON format, without
versioning. At the hard fork, `Precomputed_block` will have a stable-versioned module
`V2`. We'd like to add the version-tagging mechanism for the stable version, while
also being able to read older blocks, so tools like `archive_blocks` can use them.

In `Precomputed_block`, we can define a module:
```ocaml
 module Legacy = struct
   type t = ... [@@deriving yojson]
 end
```
where `t` uses the original definition of the precomputed block type.

Then, in `Precomputed_block`, define:
```ocaml
  let of_yojson_legacy_or_versioned json =
    match json with
	| `Assoc [("version",_); ("data", _)] -> of_yojson_to_latest_opt json
	| _ -> Legacy.of_yojson json
```

## Drawbacks
[drawbacks]: #drawbacks

There is a modest implementation effort required.

## Rationale and alternatives
[rationale-and-alternatives]: #rationale-and-alternatives

Instead of defining the `Legacy` module for precomputed blocks, it's possible to
rewrite the cache with version tags added to the JSON. That can be done with
an automation script. Once that's done, we could treat precomputed block JSON
in a uniform way, without special handling for legacy blocks.

## Prior art
[prior-art]: #prior-art

The existing versioning system is prior art, and RFC 0047 describes
top-tagging for `Bin_prot`-serialized data.

## Unresolved questions
[unresolved-questions]: #unresolved-questions

Besides precomputed blocks, are there other types that would benefit
from versioning their JSON?

Is it worth version-tagging the existing precomputed block on Google Cloud?

Are there any use cases for versioning S-expression data?