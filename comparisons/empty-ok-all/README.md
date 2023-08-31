# Comparison - Empty OK All

This comparison measures raw IO rate, the server needs to respond to requests on port :8080 with 200 OK.

Of course this is not a full picture but you can get an idea of performance.

## Results

Taken on Pop!_OS Linux using a AMD Ryzen 7 5800X 8-core processor.

Load is created using [Bombardier](https://github.com/codesenberg/bombardier) set to 250 connections and 10.000.000 requests.

Bombardier command used: `bombardier -c 250 -n 10000000 http://localhost:8080`

| Language/framework | Command                                                   | Requests per second | Total time | Avg response time | Throughput |
|--------------------|-----------------------------------------------------------|---------------------|------------|-------------------|------------|
| Rust Actix  4.2    | `cargo build --release` (this installs 256 dependencies!) | 792k                | 12s        | 310us             | 135.8MB/s  |
| Odin-HTTP   dev    | `odin build . -o:speed -disable-assert -no-bounds-check`  | 617k                | 16s        | 401us             | 92.25MB/s  |
| Go net/http 1.21   | `go build main.go`                                        | 574k                | 17s        | 430us             | 75.56MB/s  |
| Bun.serve   0.8    | `NODE_ENV=production bun run index.ts`                    | 275k                | 36s        | 0.91ms            | 35.93MB/s  |
| Node http   20.5   | `NODE_ENV=production node app.js`                         |  65k                | 2m35s      | 3.88ms            | 12.90MB/s  |
