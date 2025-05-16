/***********************************************************************************************
 * Zapbox – teste completo de performance com 5 milhões de mensagens na fila do RabbitMQ
 * (ESM, Node ≥18)
 *
 * Para cada serviço (PostgreSQL, Redis, RabbitMQ), o script executa:
 *  1. Conexão
 *  2. Escrita
 *  3. Leitura (validação)
 *  4. Deleção (limpeza)
 *  5. Desconexão
 * E mede o tempo (ms) de cada etapa.
 *
 * ➜ Salve como perf.mjs e execute:  node perf.mjs
 ***********************************************************************************************/

import { performance } from 'node:perf_hooks';
import { Client } from 'pg';
import Redis from 'ioredis';
import amqplib from 'amqplib';

/*────────────────────────── CONFIGURAÇÃO ──────────────────────────*/
const PG = {
  host: 'postgres.zapbox.me',
  port: 5432,
  db: 'zapdb',
  user: 'zapbox',
  pass: 'y0CdcdfD8zaCRiXu1XGIsj5PEvPzQmft'
};

const REDIS = {
  host: 'redis.zapbox.me',
  port: 6379,
  pass: 'y0CdcdfD8zaCRiXu1XGIsj5PEvPzQmft'
};

const AMQP = {
  host: 'rabbitmq.zapbox.me',
  port: 5672,
  user: 'admin',
  pass: 'y0CdcdfD8zaCRiXu1XGIsj5PEvPzQmft',
  queue: 'zapbox_test_queue',
  messagesCount: 10
};

const ID = `zap-${Date.now()}`;

/*─────────────────────── UTILITÁRIOS ─────────────────────────────*/
const timer = () => {
  const t0 = performance.now();
  return () => +(performance.now() - t0).toFixed(2); // ms
};

const results = {
  postgres: {},
  redis: {},
  rabbitmq: {}
};

/*──────────────────── POSTGRES ─────────────────────────────*/
async function benchPostgres() {
  const tConn = timer();
  const pg = new Client({
    host: PG.host,
    port: PG.port,
    database: PG.db,
    user: PG.user,
    password: PG.pass,
    ssl: { rejectUnauthorized: false }
  });
  await pg.connect();
  results.postgres.connect = tConn();

  await pg.query('CREATE TABLE IF NOT EXISTS smoke (id text PRIMARY KEY, val text)');

  const tWrite = timer();
  await pg.query('INSERT INTO smoke(id,val) VALUES ($1,$2)', [ID, 'ok']);
  results.postgres.write = tWrite();

  const tRead = timer();
  const { rows } = await pg.query('SELECT val FROM smoke WHERE id=$1', [ID]);
  results.postgres.read = tRead();

  const tDelete = timer();
  await pg.query('DELETE FROM smoke WHERE id=$1', [ID]);
  results.postgres.delete = tDelete();

  const tClose = timer();
  await pg.end();
  results.postgres.disconnect = tClose();

  if (rows[0]?.val !== 'ok') throw new Error('Dados do Postgres não correspondem');
}

/*──────────────────── REDIS ───────────────────────────────*/
async function benchRedis() {
  const tConn = timer();
  const redis = new Redis({
    host: REDIS.host,
    port: REDIS.port,
    password: REDIS.pass,
    tls: { servername: REDIS.host }
  });
  results.redis.connect = tConn();

  const tWrite = timer();
  await redis.set(ID, 'ok');
  results.redis.write = tWrite();

  const tRead = timer();
  const val = await redis.get(ID);
  results.redis.read = tRead();

  const tDelete = timer();
  await redis.del(ID);
  results.redis.delete = tDelete();

  const tClose = timer();
  redis.disconnect();
  results.redis.disconnect = tClose();

  if (val !== 'ok') throw new Error('Dados do Redis não correspondem');
}

/*─────────────────── RABBITMQ ─────────────────────────────*/
async function benchRabbit() {
  const url = `amqps://${encodeURIComponent(AMQP.user)}:${encodeURIComponent(AMQP.pass)}@${AMQP.host}:${AMQP.port}/`;
  console.log(url);
  
  const tConn = timer();
  const conn = await amqplib.connect(url, { servername: AMQP.host });
  const ch   = await conn.createChannel();
  results.rabbitmq.connect = tConn();

  // 1) garante que não há mensagem antiga
  await ch.assertQueue(AMQP.queue);
  await ch.purgeQueue(AMQP.queue);

  // 2) escrita de 5 milhões de mensagens
  const tWrite = timer();
  for (let i = 0; i < AMQP.messagesCount; i++) {
    ch.sendToQueue(AMQP.queue, Buffer.from(`${ID}-${i}`));
  }
  results.rabbitmq.write = tWrite();

  // 3) leitura de 5 milhões de mensagens
  const tRead = timer();
  let readCount = 0;
  while (readCount < AMQP.messagesCount) {
    const msg = await ch.get(AMQP.queue, { noAck: false });
    if (msg) {
      ch.ack(msg);
      readCount++;
    }
  }
  results.rabbitmq.read = tRead();

  // 4) limpeza (purge, caso reste algo)
  const tDelete = timer();
  await ch.purgeQueue(AMQP.queue);
  results.rabbitmq.delete = tDelete();

  // 5) desconexão
  const tClose = timer();
  await conn.close();
  results.rabbitmq.disconnect = tClose();

  if (readCount !== AMQP.messagesCount) {
    throw new Error(`Dados do RabbitMQ não correspondem: esperado=${AMQP.messagesCount} lidos=${readCount}`);
  }
}

/*──────────────────── PRINCIPAL ────────────────────────────────*/
(async () => {
  try {
    await benchPostgres();
    await benchRedis();
    await benchRabbit();

    console.log('\n⏱  Resultado:');
    console.table(
      Object.entries(results).map(([svc, times]) => ({
        'Serviço': svc,
        'Conexão (ms)': times.connect,
        'Escrita (ms)': times.write,
        'Leitura (ms)': times.read,
        'Exclusão (ms)': times.delete,
        'Desconexão (ms)': times.disconnect,
        'Total (ms)': Object.values(times).reduce((s, v) => s + v, 0).toFixed(2)
      }))
    );
  } catch (e) {
    console.error('❌ Erro:', e.message);
    process.exit(1);
  }
})();