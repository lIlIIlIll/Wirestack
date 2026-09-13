# Third-party notices

Wirestack release artifacts include AWS-LC 5.5.0 as a statically linked TLS
provider. The provider source is pinned to commit
`991e67ff4cf04df4dd89e407f8b920c6936cb56a`.

AWS-LC declares `Apache-2.0 OR ISC` for AWS-LC files. Its source tree also
contains code under the licenses listed in
[`third_party/aws-lc/LICENSE`](third_party/aws-lc/LICENSE). The release artifact
includes that complete license inventory and the upstream
[`third_party/aws-lc/NOTICE`](third_party/aws-lc/NOTICE).

Wirestack does not modify the copied AWS-LC license or notice text.

The HTTP CookieJar uses the Public Suffix List, including its ICANN and PRIVATE
sections, from upstream commit `3955e3ec29b94c3cca7bd4509c5f14a7c0959e26`.
The original list and the generated lookup data are covered by MPL-2.0.
The release includes the [complete license](third_party/public_suffix/LICENSE.MPL-2.0),
[upstream snapshot](third_party/public_suffix/public_suffix_list.dat),
[source identity and digests](third_party/public_suffix/source.json), and
[offline generator](third_party/public_suffix/generate.py).
The generated source identifies its upstream revision and snapshot digest.
