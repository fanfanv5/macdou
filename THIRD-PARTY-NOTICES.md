# Third-party software

## libusb

The built Mac application dynamically links libusb, licensed under
LGPL-2.1-or-later. `scripts/build-app.sh` copies the library and its full
`COPYING` license from `LIBUSB_PREFIX` into the application bundle as
`Contents/MacOS/libusb-1.0.0.dylib` and
`Contents/Resources/libusb-LICENSE.txt`.

Upstream source and release archives: https://github.com/libusb/libusb

The library remains a separate dylib. A compatible rebuilt library can replace
it in a local bundle; the modified bundle must be re-signed before launch.
Nothing in this notice restricts modification of libusb or reverse engineering
needed to debug such modifications. See the LGPL license packaged with the app.

MacDou does not include libusb source or binary artifacts in this repository.
