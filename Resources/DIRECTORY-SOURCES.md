# Radio directory sources

Checked October 29, 2026. RadioPocket connects directly to each enabled source only when browsing. Audio is played from the station’s own URL.

| Source | Public interface | Initial state |
| --- | --- | --- |
| [Radio Browser](https://www.radio-browser.info/) | [JSON API](https://docs.radio-browser.info/) | Enabled |
| [SomaFM](https://somafm.com/) | https://somafm.com/channels.json | Enabled |
| [laut.fm](https://laut.fm/) | [Station API](https://docs.api.laut.fm/) and [Search API](https://search.api.laut.fm/v1/docs/) | Enabled |
| [Radio Paradise](https://radioparadise.com/listen/stream-links) | [Published direct AAC links](https://img.radioparadise.com/content/prod/listen/streams/template.html) | Enabled |
| [Curated Internet Radio Streams](https://github.com/mikepierce/internet-radio-streams) | Root M3U files from Mike Pierce’s public repository | Enabled |
| [Icecast / Xiph](https://dir.xiph.org/) | https://dir.xiph.org/yp.xml | Optional, unchecked |
| [IPRD](https://iprd-org.github.io/iprd/catalog/) | [Complete M3U](https://iprd-org.github.io/iprd/site_data/all_stations.m3u) | Optional, unchecked |
| [Junguler Radio Playlists](https://github.com/junguler/m3u-radio-music-playlists) | [Named M3U collection](https://raw.githubusercontent.com/junguler/m3u-radio-music-playlists/main/---everything-full.m3u) | Optional, unchecked |

Icecast, IPRD and Junguler supply full catalogs. They are opt-in to avoid downloading multi-megabyte lists during ordinary searches. Catalogs cache in memory for ten minutes. Icecast is capped at 16 MiB, IPRD at 8 MiB and 30,000 entries, custom playlists at 2 MiB and 5,000 entries. laut.fm requests at most 100 records per page and retains six pages for ten minutes. Junguler is capped at 8 MiB and 50,000 entries and uses the named version, preserving playlist sections as genre tags. The opening views (Popular, Top Rated, A–Z) of the enabled sources are saved on disk and refreshed in the background about every six hours, one request at a time, unless Preferences ▸ Media Library turns that off; a downloaded full catalog is released from memory afterwards.

Radio Paradise contributes four published 128 kbps AAC mixes (Main, Mellow, Rock and World / Etc), without a catalog download. These links are built in; no artwork or audio is bundled. Its streams were checked for an audio response on October 29, 2026.

Mike Pierce’s collection is fetched on demand in one small ZIP request from GitHub, limited to 1 MiB compressed and 2 MiB of playlist text, with at most 256 root-level M3U files and 5,000 entries. Files in DEMOTED are excluded. Only playlist text is read; repository paths are never extracted to disk. The temporary archive is removed after reading and station listings cache in memory for ten minutes. No playlists from either GitHub collection are redistributed in the app. Attribution is retained here and in source labels. Availability and metadata quality depend on the collection’s maintainers.

Country, bitrate and codec filters can hide entries when the source supplies no matching metadata. laut.fm results use provider paging and are filtered and sorted within each page; they do not offer Radio Browser’s global ordering. A page can be empty after filtering while Next remains available. Directory entries can overlap; combined searches deduplicate identical stream URLs.

SHOUTcast was reviewed, but its [developer page](https://directory.shoutcast.com/Developer) directs application developers to a partnership arrangement. No undocumented API or credentials are bundled.

## IPRD attribution

Catalog maintained by IPRD Contributors: https://github.com/iprd-org/iprd

MIT License

Copyright (c) 2025 IPRD Contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
