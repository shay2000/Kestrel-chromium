# Attachment file-type marks

Kestrel uses Microsoft Fluent file-type SVGs in the New Tab and Assistant attachment trays. The marks are bundled locally in `KestrelWebKit/Assets.xcassets`, so showing an attachment never makes a network request.

The assets come from the official [`@fluentui/react-file-type-icons`](https://github.com/microsoft/fluentui/tree/master/packages/react-file-type-icons) file-type set, using its 24-pixel SVGs from Microsoft CDN release `20260623.001`. Microsoft describes these as icons for identifying file formats and recommends SVG where scalable artwork is useful in a UI ([Fluent iconography guidance](https://fluent2.microsoft.design/iconography)).

| Attachment formats | Bundled mark |
| --- | --- |
| Word documents and templates (`doc`, `docm`, `docx`, `dot*`) | `AttachmentWord` |
| Spreadsheets and delimited tables (`xls*`, `xlt*`, `xlsx`, `csv`, `tsv`) | `AttachmentExcel` |
| Presentations and slide decks (`pot*`, `pps*`, `ppt*`, `sld*`) | `AttachmentPowerPoint` |
| PDF | `AttachmentPDF` |
| Images | `AttachmentImage` |
| Supported plain text and source files | `AttachmentText` |
| Other file extensions | `AttachmentGeneric` |

Each tray uses a fixed 20-by-20-point image slot and a 30-point chip height. The filename remains the accessible text label; tab attachments keep their tab symbol in that same slot.
