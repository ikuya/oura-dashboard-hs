# Vendored libraries

Third-party scripts served locally instead of from a CDN, pinned to exact
versions. Each file is the unmodified build from the npm package tarball.

| File | Package | Source path in package |
| --- | --- | --- |
| `chart-4.5.1.umd.min.js` | `chart.js@4.5.1` | `dist/chart.umd.min.js` |
| `luxon-3.7.2.min.js` | `luxon@3.7.2` | `build/global/luxon.min.js` |
| `chartjs-adapter-luxon-1.3.1.umd.min.js` | `chartjs-adapter-luxon@1.3.1` | `dist/chartjs-adapter-luxon.umd.min.js` |
| `marked-12.0.2.min.js` | `marked@12.0.2` | `marked.min.js` |
| `purify-3.2.6.min.js` | `dompurify@3.2.6` | `dist/purify.min.js` |

All are MIT licensed except DOMPurify (Apache-2.0 or MPL-2.0, at the user's
choice); the license texts are in `licenses/`.

To upgrade, download the new tarball (`https://registry.npmjs.org/<pkg>/-/<pkg>-<ver>.tgz`),
copy the file above under the new versioned name, delete the old one, and update
the `<script>` tags in `static/index.html` and this table.
