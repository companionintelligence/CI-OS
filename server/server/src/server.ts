import http from 'http';

const PORT = process.env.PORT || 3000;

const requestHandler = (request: http.IncomingMessage, response: http.ServerResponse) => {
    response.setHeader('Content-Type', 'text/plain');
    response.end('Hello, World!\n');
};

const server = http.createServer(requestHandler);

server.listen(PORT, () => {
    console.log(`Server is running on http://localhost:${PORT}`);
});


const host = "localhost";
const protocol = "https";
const port = 9200;
const auth = "admin:GhericS2022!"; // For testing only. Don't store credentials in code.
const ca_certs_path = "/full/path/to/root-ca.pem";

// Optional client certificates if you don't want to use HTTP basic authentication.
// const client_cert_path = '/full/path/to/client.pem'
// const client_key_path = '/full/path/to/client-key.pem'

// Create a client with SSL/TLS enabled.
const { Client } = require("@opensearch-project/opensearch");
const fs = require("fs");
const client = new Client({
  node: `${protocol}://${auth}@${host}:${port}`,
  ssl: {
    ca: fs.readFileSync(ca_certs_path),
    // You can turn off certificate verification (rejectUnauthorized: false) if you're using 
    // self-signed certificates with a hostname mismatch.
    // cert: fs.readFileSync(client_cert_path),
    // key: fs.readFileSync(client_key_path)
  },
});


const index_name = "events";

const settings = {
  settings: {
    index: {
      number_of_shards: 4,
      number_of_replicas: 3,
    },
  },
};

const response = await client.indices.create({
  index: index_name,
  body: settings,
});