const feathers = require('@feathersjs/feathers');
const koa = require('@feathersjs/koa');
const socketio = require('@feathersjs/socketio');

// Create a Koa compatible Feathers application
const app = koa(feathers());

// Enable Socket.io
app.configure(socketio());

// Enable REST services
app.configure(koa.rest());

// A simple Message service that we can use for testing
app.use('/messages', {
  async find() {
    return [{ text: 'Hello from the Feathers API with Koa' }];
  }
});

// Start the server
const port = 3030;
app.listen(port).on('listening', () =>
  console.log(`Feathers server with Koa listening on http://localhost:${port}`)
);