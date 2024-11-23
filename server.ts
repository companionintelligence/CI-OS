import { Application, Router } from "https://deno.land/x/oak/mod.ts";

const app = new Application();
const router = new Router();

router
  .post("/login", async (context) => {
    const { value } = await context.request.body();
    const { username, password } = value;
    if (username === "admin" && password === "password") {
      context.response.body = { success: true, token: "dummy-token" };
    } else {
      context.response.status = 401;
      context.response.body = { success: false, message: "Invalid credentials" };
    }
  })
  .get("/dashboard", (context) => {
    context.response.body = { message: "Welcome to the dashboard!" };
  });

app.use(router.routes());
app.use(router.allowedMethods());

console.log("Server is running on http://localhost:8000");
await app.listen({ port: 8000 });