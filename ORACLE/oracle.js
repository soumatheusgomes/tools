// oracle.js — OCI Node/TypeScript SDK + Cloudflare SDK v4
// ----------------------------------------------------------------------------
// 1. Run once → node oracle.js   ➜ lista imagens Ubuntu 24.04 e provisiona instância.
// 2. Copia OCID da imagem, cria instância, instala Docker e adiciona A-record no Cloudflare.
// ----------------------------------------------------------------------------



const fs = require('node:fs');
const core = require('oci-core');
const common = require('oci-common');
const identitySdk = require('oci-identity');
const { execSync } = require('child_process');
const Cloudflare = require('cloudflare').default;

require('dotenv').config();

//───────────────────────── ENV ─────────────────────────
const {
  ORACLE_TENANCY_ID,
  ORACLE_REGION,
  CLOUDFLARE_API_TOKEN,
  CLOUDFLARE_ZONE_ID,
  DOMAIN_NAME
} = process.env;

//────────────────── OCI AUTH PROVIDER ──────────────────
const provider = new common.ConfigFileAuthenticationDetailsProvider(
  '~/.oci/config',
  'DEFAULT'
);

//────────────────── OCI CLIENTS ────────────────────────
const computeClient = new core.ComputeClient({ authenticationDetailsProvider: provider });
const networkClient = new core.VirtualNetworkClient({ authenticationDetailsProvider: provider });
computeClient.regionId = ORACLE_REGION;
networkClient.regionId = ORACLE_REGION;

//────────────────── Cloudflare CLIENT ───────────────────
const cf = new Cloudflare({ apiToken: CLOUDFLARE_API_TOKEN });

//────────────────── UTILITÁRIOS ────────────────────────
const DEFAULT_SSH_OPTS = [
  '-o StrictHostKeyChecking=no',
  '-o ConnectTimeout=10',
  '-o BatchMode=yes',
  '-o ServerAliveInterval=60',
  '-o ServerAliveCountMax=3',
];

const sleep = ms => new Promise(res => setTimeout(res, ms));

function sshExecSync(ip, command, { user = 'ubuntu', sshOpts = DEFAULT_SSH_OPTS } = {}) {
  const flags = sshOpts.join(' ');
  const safeCmd = command.replace(/"/g, '\\"');
  return execSync(`ssh ${flags} ${user}@${ip} "${safeCmd}"`, { stdio: 'inherit' });
}

async function waitForHostOnline(ip, { user = 'ubuntu', sshOpts = DEFAULT_SSH_OPTS, maxWait = 300000, interval = 5000 } = {}) {
  const flags = sshOpts.join(' ');
  const start = Date.now();
  process.stdout.write('⌛ aguardando host online ');
  while (Date.now() - start < maxWait) {
    try {
      execSync(`ssh ${flags} ${user}@${ip} "echo ok"`, { stdio: 'ignore' });
      console.log('\n✅ Host online.');
      return;
    } catch {
      process.stdout.write('.');
      await sleep(interval);
    }
  }
  throw new Error('Timeout aguardando host online');
}

async function waitForCommand(
  ip,
  command,
  { user = 'ubuntu', sshOpts = DEFAULT_SSH_OPTS, retries = 10, delay = 5000 } = {}
) {
  const flags = sshOpts.join(' ');
  let lastErr;
  for (let i = 1; i <= retries; i++) {
    try {
      const output = execSync(
        `ssh ${flags} ${user}@${ip} "${command.replace(/"/g, '\\"')}"`,
        { encoding: 'utf8' }
      ).trim();
      console.log(`✅ Comando disponível [${i}/${retries}]: ${command} → ${output}`);
      return output;
    } catch (err) {
      lastErr = err;
      process.stdout.write(`⏳ tentativa ${i}/${retries} falhou para "${command}". esperando ${delay/1000}s… `);
      await sleep(delay);
    }
  }
  console.error();
  throw new Error(`⛔ comando "${command}" não disponível após ${retries} tentativas`);
}

async function uploadScript(ip, localScript, { user = 'ubuntu', sshOpts = DEFAULT_SSH_OPTS } = {}) {
  const flags = sshOpts.join(' ');
  console.log(`📦 enviando ${localScript}…`);
  execSync(`scp ${flags} ${localScript} ${user}@${ip}:~/server-setup.sh`, { stdio: 'inherit' });
}

//────────────────── 1) LIST UBUNTU IMAGES ───────────────────
async function listUbuntuImages() {
  const resp = await computeClient.listImages({
    compartmentId: ORACLE_TENANCY_ID,
    operatingSystem: 'Canonical Ubuntu',
    operatingSystemVersion: '24.04'
  });
  const buildTag = '2025.03.28-0';
  const images = resp.items.filter(img =>
    (img['display-name'] || img.displayName).includes(buildTag)
  );
  console.table(images.map(img => ({
    id: img.id,
    name: img['display-name'] || img.displayName
  })));
  return images;
}

//────────────────── helper → default subnet ───────────────
async function getDefaultSubnet() {
  // const { items: vcns } = await networkClient.listVcns({ compartmentId: ORACLE_TENANCY_ID });
  // const vcnId = vcns[0].id;
  // const { items: subs } = await networkClient.listSubnets({ compartmentId: ORACLE_TENANCY_ID, vcnId });
  // return subs[0].id;
  return 'ocid1.subnet.oc1.sa-saopaulo-1.aaaaaaaah2d5x3obm6uyr6ihld5e4zfxtxerqupj4qv7tkmc7xdb7psgsj6a';
}

//────────────────── helper → first AD ────────────────────
async function firstAd() {
  const identity = new identitySdk.IdentityClient({ authenticationDetailsProvider: provider });
  identity.regionId = ORACLE_REGION;
  const { items } = await identity.listAvailabilityDomains({ compartmentId: ORACLE_TENANCY_ID });
  if (!items.length) throw new Error('Nenhum AD encontrado');
  return items[0].name;
}

//────────────────── helper → wait RUNNING ─────────────────
async function waitUntilRunning(instanceId, maxTries = 30, delay = 15000) {
  for (let i = 1; i <= maxTries; i++) {
    const { instance } = await computeClient.getInstance({ instanceId });
    if (instance.lifecycleState === core.models.Instance.LifecycleState.Running) return instance;
    console.log(`⏳ estado RUNNING (${i}/${maxTries})`);
    await sleep(delay);
  }
  throw new Error('Timeout esperando RUNNING');
}

//────────────────── helper → public IP ────────────────────
async function fetchPublicIp(instance, maxTries = 20, delay = 5000) {
  for (let i = 1; i <= maxTries; i++) {
    const { items } = await computeClient.listVnicAttachments({
      compartmentId: ORACLE_TENANCY_ID,
      instanceId: instance.id
    });
    if (items.length) {
      const vnicId = items[0].vnicId;
      const { vnic } = await networkClient.getVnic({ vnicId });
      const ip = vnic.publicIp || vnic.publicIpAddress;
      if (ip) return ip;
    }
    console.log(`⏳ aguardando IP público (${i}/${maxTries})`);
    await sleep(delay);
  }
  return null;
}

//────────────────── 2) CREATE INSTANCE ───────────────────
async function createInstance(imageId, availabilityDomain, instanceName) {
  const details = {
    compartmentId: ORACLE_TENANCY_ID,
    availabilityDomain,
    shape: 'VM.Standard.E4.Flex',
    shapeConfig: { ocpus: 1, memoryInGBs: 8 },
    displayName: instanceName,
    sourceDetails: { sourceType: 'image', imageId },
    metadata: {
      ssh_authorized_keys: fs.readFileSync(`${process.env.HOME}/.ssh/id_ed25519.pub`, 'utf8')
    },
    createVnicDetails: {
      assignPublicIp: true,
      subnetId: await getDefaultSubnet()
    }
  };
  const { instance } = await computeClient.launchInstance({ launchInstanceDetails: details });
  console.log('Instance OCID →', instance.id);
  return instance;
}

//────────────────── 3) BOOTSTRAP DOCKER ──────────────────
async function bootstrapDocker(ip, localScript = './server-setup.sh', options = {}) {
  const { user = 'ubuntu', sshOpts = DEFAULT_SSH_OPTS, maxRebootWait = 300000 } = options;

  console.log('🚀 atualizando sistema + kernel …');
  try {
    sshExecSync(ip, `
      sudo bash -c '
        set -euo pipefail
        systemctl stop apt-daily{,-upgrade}.{service,timer} || true
        systemctl kill --kill-who=all apt-daily{,-upgrade}.service || true
        while pgrep -x apt >/dev/null || pgrep -x unattended-upgrade >/dev/null; do sleep 1; done
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -yq
        apt-get full-upgrade -yq
        apt-get autoremove -yq
        apt-get clean
        reboot
      '
    `, { user, sshOpts });
  } catch { /* desconexão esperada */ }

  await waitForHostOnline(ip, { user, sshOpts, maxWait: maxRebootWait });
  await uploadScript(ip, localScript, { user, sshOpts });

  console.log('🔧 executando setup no servidor…');
  sshExecSync(ip, 'chmod +x ~/server-setup.sh && sudo ~/server-setup.sh', { user, sshOpts });

  console.log('♻️ reiniciando servidor para aplicar alterações…');
  try {
    sshExecSync(ip, 'sudo reboot', { user, sshOpts });
  } catch { /* desconexão esperada */ }

  await waitForHostOnline(ip, { user, sshOpts, maxWait: maxRebootWait });

  console.log('\n🔍 validando instalação do Docker…');
  await waitForCommand(ip, 'docker --version', { user, sshOpts, retries: 12, delay: 5000 });

  console.log('🏁 provisionamento concluído ✅');
}

//────────────────── 4) CLOUDFLARE DNS ───────────────────
async function createDnsRecord(publicIp, instanceName) {
  const record = {
    zone_id: CLOUDFLARE_ZONE_ID || 'a4ce24f5629a101be121bd5735fc1a17',
    type: 'A',
    name: `${instanceName}.${DOMAIN_NAME}`,
    content: publicIp,
    ttl: 1,
    proxied: true
  };
  const result = await cf.dns.records.create(record);
  console.log('Cloudflare DNS ✔︎ →', result);
}

//────────────────── PLAYGROUND ─────────────────────────
(async () => {
  const instanceName = 'zapbox-teste-3';

  await listUbuntuImages();

  const imgId = 'ocid1.image.oc1.sa-saopaulo-1.aaaaaaaaizp5gtxmllal26ba7bnjonrjy6au47uqhvwnoanpdhxfcvtklutq';
  const ad = await firstAd();

  const instance = await createInstance(imgId, ad, instanceName);
  const running = await waitUntilRunning(instance.id);
  const ip = await fetchPublicIp(running);
  if (!ip) throw new Error('IP público não disponível');

  await createDnsRecord(ip, instanceName);

  // aguarda 15s antes de iniciar o bootstrap
  await sleep(15000);
  await bootstrapDocker(ip);
})();