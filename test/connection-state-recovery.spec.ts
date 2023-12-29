import { createServer } from "http";
import { Server } from "socket.io";
import { io as ioc } from "socket.io-client";
import { MongoClient } from "mongodb";
import { createAdapter } from "../lib";
import { AddressInfo } from "net";
import waitForExpect from "wait-for-expect";
import { sleep } from "./util";

const NODES_COUNT = 3;

describe("connection state recovery", () => {
  let servers: Server[];
  let ports: number[];
  let mongoClient: MongoClient;

  beforeEach(async () => {
    servers = [];
    ports = [];

    mongoClient = new MongoClient(
      "mongodb://localhost:27017/?replicaSet=rs0&directConnection=true"
    );
    await mongoClient.connect();

    const collection = mongoClient.db("test").collection("events");

    for (let i = 1; i <= NODES_COUNT; i++) {
      const httpServer = createServer();
      const io = new Server(httpServer, {
        pingInterval: 1500,
        pingTimeout: 1600,
        connectionStateRecovery: {
          maxDisconnectionDuration: 5000,
        },
        adapter: createAdapter(collection),
      });
      httpServer.listen(async () => {
        const port = (httpServer.address() as AddressInfo).port;

        servers.push(io);
        ports.push(port);
      });
    }

    // Wait for all connections being established (done in loop above)
    await waitForExpect(async () => {
      expect(servers.length).toEqual(NODES_COUNT);
    });

    // TODO: find a better way to wait for all nodes to be connected
    await sleep(200);
  });

  afterEach(async () => {
    servers.forEach((server) => {
      // @ts-ignore
      server.httpServer.close();
      server.of("/").adapter.close();
      server.of("/foo").adapter.close();
    });

    // TODO: somehow this still raises an error "connection establishment was cancelled"
    // try {
    //   await mongoClient.close();
    // } catch {
    //   // ignore, we are in teardown
    // }
  });

  it("should restore the session", (done) => {
    const socket = ioc(`http://localhost:${ports[0]}`, {
      reconnectionDelay: 20,
    });

    let initialId: string;

    socket.once("connect", async () => {
      expect(socket.recovered).toEqual(false);
      initialId = socket.id;

      servers[0].emit("init");
    });

    socket.on("init", () => {
      // under the hood, the client saves the offset of this packet, so now we force the reconnection
      socket.io.engine.close();

      socket.on("connect", () => {
        expect(socket.recovered).toEqual(true);
        expect(socket.id).toEqual(initialId);

        socket.disconnect();
        done();
      });
    });
  });

  it("should restore any missed packets", (done) => {
    const socket = ioc(`http://localhost:${ports[0]}`, {
      reconnectionDelay: 20,
    });

    servers[0].once("connection", (socket) => {
      socket.join("room1");

      socket.on("disconnect", () => {
        // let's send some packets while the client is disconnected
        socket.emit("myEvent", 1);
        servers[0].emit("myEvent", 2);
        servers[0].to("room1").emit("myEvent", 3);

        // those packets should not be received by the client upon reconnection (room mismatch)
        servers[0].to("room2").emit("myEvent", 4);
        servers[0].except("room1").emit("myEvent", 5);
        servers[0].of("/foo").emit("myEvent", 6);
      });
    });

    socket.once("connect", () => {
      servers[1].emit("init");
    });

    socket.on("init", () => {
      // under the hood, the client saves the offset of this packet, so now we force the reconnection
      socket.io.engine.close();

      socket.on("connect", () => {
        expect(socket.recovered).toEqual(true);

        setTimeout(() => {
          expect(events).toEqual([1, 2, 3]);

          socket.disconnect();
          done();
        }, 50);
      });
    });

    const events: number[] = [];

    socket.on("myEvent", (val) => {
      events.push(val);
    });
  });

  it("should fail to restore an unknown session (invalid session ID)", (done) => {
    const socket = ioc(`http://localhost:${ports[0]}`, {
      reconnectionDelay: 20,
    });

    socket.once("connect", () => {
      // @ts-ignore
      socket._pid = "abc";
      // @ts-ignore
      socket._lastOffset = "507f191e810c19729de860ea";
      // force reconnection
      socket.io.engine.close();

      socket.on("connect", () => {
        expect(socket.recovered).toEqual(false);

        socket.disconnect();
        done();
      });
    });
  });

  it("should fail to restore an unknown session (invalid offset)", (done) => {
    const socket = ioc(`http://localhost:${ports[0]}`, {
      reconnectionDelay: 20,
      upgrade: false,
    });

    socket.once("connect", () => {
      // @ts-ignore
      socket._lastOffset = "abc";
      socket.io.engine.close();

      socket.on("connect", () => {
        expect(socket.recovered).toEqual(false);

        socket.disconnect();
        done();
      });
    });
  });
});
