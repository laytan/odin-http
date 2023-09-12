# Comparison - Empty OK All

This comparison measures raw IO rate, the server needs to respond to requests on port :8080 with 200 OK.

Of course this is not a full picture but you can get an idea of performance.

## Results

Taken on Pop!_OS Linux using a AMD Ryzen 7 5800X 8-core processor.

Load is created using [Bombardier](https://github.com/codesenberg/bombardier) set to 250 connections and 10.000.000 requests.

Bombardier command used: `bombardier -c 250 -n 10000000 http://localhost:8080`

| Language/framework | Command                                                   | Requests per second | Total time | Avg response time | Throughput |
|--------------------|-----------------------------------------------------------|---------------------|------------|-------------------|------------|
| Rust Actix  4.2    | `cargo build --release` (this installs 256 dependencies!) | 712k                | 14s        | 347us             | 120.8MB/s  |
| Odin-HTTP   dev    | `odin build . -o:speed -disable-assert -no-bounds-check`  | 637k                | 15s        | 340us             | 105.2MB/s  |
| Go net/http 1.21   | `go build main.go`                                        | 598k                | 16s        | 417us             | 77.98MB/s  |
| Bun.serve   1.1    | `NODE_ENV=production bun run index.ts`                    | 302k                | 33s        | 827us             | 39.43MB/s  |
| Node http   20.5   | `NODE_ENV=production node app.js`                         |  65k                | 2m35s      | 3.88ms            | 12.90MB/s  |
