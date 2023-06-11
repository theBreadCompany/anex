# anex

A script to export Apple notes to HTML and PDF

## disclaimer

This is in no way affiliated to Apple. By using this project, you also agree to Apple's licensing that applies to Apple Notes. Neither they nor myself grant any form of warranty or other forms of compensation in cases of data loss or other software or hardware related damage. Use at your own caution!

Also, this is a command line utility. Basic knowledge of the mentioned terms is advised.

## prerequisites

You need a Mac, a (healthy) notes store and installed _Xcode Command Line Utilites_, which should include sqlite3 and zlib.

## build

`cd` into the directory you downloaded the source and call `clang -framework Foundation -framework ScriptingBridge -framework UniformTypeIdentifiers -framework CoreServices -framework CoreGraphics -framework CoreText -framework AppKit -lz -lsqlite3 -isysroot /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk -target arm64-apple-macosx10.13 -fobjc-arc anex/main.m -o anexx` (anexx because clang otherwise complains about the name conflicting with directory).

## use

After you either downloaded [a release](https://github.com/thebreadcompany/anex/releases/latest/anex.zip) of anex or built it yourself, you may execute it by `cd`ing into the location of the binary and calling `./anex`. A list of options will be displayed:
```
Usage: anex <output-dir> [--create-indices | --embed-media | --copy-media | --as-pdf | --embed-media | --custom-stylesheet <file>]
<output-dir>        an output directory to write to; will be created if not existing
--create-indices    create index files in the output, account and folder directories
--embed-media       embed files in the HTML documents, making them portable; do not use with --copy-media
--as-pdf            export all notes as PDF; --create-indices will be ignored for now
--as-md				export all notes as markdown; --create-indices will be ignored for now
--copy-media        copy files to the output directory; do not use with --embed-media
--custom-stylesheet use the custom stylesheet <file>; will be either copied (default) or embedded
--embed-stylesheet  embed the stylesheet in each HTML file
```

Please keep in mind that nothing is portable as long as you dont embed anything. Indices use relative paths, media absolute ones. If you want to archive your notes and delete the stuff in iCloud, you need to use `--embed-media` or simply export as PDF with `--as-pdf` altogether as files the HTMLs are pointing to will not be there anymore!

By default, a default set of styles is used and all notes are exported as HTML without any indices and no media embedded.

## exporting

HTML is thought to be a base for further conversions, although direct PDF export is supported as well.

## TODO

- nicer default CSS (especially media stuff)
- fancy javascript stuff, including a darkmode switch for HTML?
- what the hell is my code, not to mention my CSS
- why does CoreGraphics crash with certain PDF pages

## additional notes

- The `Notes.h` in the anex folder has been created using the `sdef` and `sdp` utilities.
- The colors have been identified using the "Digital Color Meter" app provided in macOS. Feel free to change anything in there.
- If `CoreGraphics PDF has logged an error. Set environment variable "CG_PDF_VERBOSE" to learn more.`, don't worry. Your PDF pages might fall back on some fonts or something.

## credits

- [Apple](https://apple.com) for creating a really nice app to take notes - its nice to see how it has evolved and can now basically do anything I want (except clean exports of notes ._.)
- [w3schools.com](https://w3schools.com) - Really, I have pretty much no idea of CSS and would have quite a problem without these guys. Most of the UI elements in the HTML are from them, thanks for your work :).
