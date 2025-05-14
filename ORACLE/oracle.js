// oracle.js — OCI Node/TypeScript SDK (latest) + Cloudflare SDK v4
// ----------------------------------------------------------------------------
// 1. Run once → node oracle.js   ➜ lists Canonical Ubuntu 24.04 images (build 2025‑03‑28‑0).
// 2. Copy the image OCID & let the script create an instance, install Docker,
//    and add an A‑record in Cloudflare automatically.
// ----------------------------------------------------------------------------
// npm i oci-common oci-core oci-identity cloudflare@^4 dotenv
// .env: ORACLE_TENANCY_ID  ORACLE_REGION
//       CLOUDFLARE_API_TOKEN  (CLOUDFLARE_ZONE_ID optional)  DOMAIN_NAME
// ----------------------------------------------------------------------------

const common = require("oci-common");
const core = require("oci-core");
const identitySdk = require("oci-identity");
const Cloudflare = require("cloudflare").default;
const fs = require("node:fs");
const { execSync } = require("node:child_process");
require("dotenv").config();

/*───────────────────────── ENV ─────────────────────────*/
const {
  ORACLE_TENANCY_ID,
  ORACLE_REGION,
  CLOUDFLARE_API_TOKEN,
  CLOUDFLARE_ZONE_ID,
  DOMAIN_NAME
} = process.env;

const instanceName = 'zapbox-teste-v1';

/*────────────────── OCI AUTH PROVIDER ──────────────────*/
const provider = new common.ConfigFileAuthenticationDetailsProvider(
  "~/.oci/config",
  "DEFAULT"
);

/*────────────────── OCI CLIENTS ────────────────────────*/
const computeClient = new core.ComputeClient({ authenticationDetailsProvider: provider });
const networkClient = new core.VirtualNetworkClient({ authenticationDetailsProvider: provider });
computeClient.regionId = ORACLE_REGION;
networkClient.regionId = ORACLE_REGION;

/*────────────────── Cloudflare CLIENT ───────────────────*/
const cf = new Cloudflare({ apiToken: CLOUDFLARE_API_TOKEN });

// const cf = new Cloudflare({
//   apiEmail: 'eu@matheusgom.es',
//   apiKey: '61d2068d61690110131ec0c9b85ef79409b7b',
// });

/*──────────────── 1) LIST UBUNTU IMAGES ────────────────*/
async function listUbuntuImages() {
  const req = {
    compartmentId: ORACLE_TENANCY_ID,
    operatingSystem: "Canonical Ubuntu",
    operatingSystemVersion: "24.04"
  };
  const { items } = await computeClient.listImages(req);
  const buildTag = "2025.03.28-0";
  const display = img => img["display-name"] || img.displayName || "";
  const images = items.filter(img => display(img).includes(buildTag));
  console.table(images.map(img => ({ id: img.id, name: display(img) })));
  return images;
}

/*──────── helper → default subnet ────────*/
async function getDefaultSubnet() {
  // const { items: vcns } = await networkClient.listVcns({ compartmentId: ORACLE_TENANCY_ID });
  // if (!vcns.length) throw new Error("No VCN in compartment");

  // const { id: vcnId } = vcns[0];
  // const { items: subs } = await networkClient.listSubnets({ compartmentId: ORACLE_TENANCY_ID, vcnId });
  // if (!subs.length) throw new Error("No subnet in VCN");
  // return subs[0].id;

  return 'ocid1.subnet.oc1.sa-saopaulo-1.aaaaaaaah2d5x3obm6uyr6ihld5e4zfxtxerqupj4qv7tkmc7xdb7psgsj6a'
}

/*──────── helper → first AD ────────*/
async function firstAd() {
  const identity = new identitySdk.IdentityClient({ authenticationDetailsProvider: provider });
  identity.regionId = ORACLE_REGION;
  const { items } = await identity.listAvailabilityDomains({ compartmentId: ORACLE_TENANCY_ID });
  if (!items.length) throw new Error("No AD found");
  return items[0].name; // may include prefix
}

/*──────── helper → wait RUNNING ────────*/
async function waitUntilRunning(instanceId, maxTries = 30, delay = 15000) {
  for (let i = 1; i <= maxTries; i++) {
    const { instance } = await computeClient.getInstance({ instanceId });
    if (instance.lifecycleState === core.models.Instance.LifecycleState.Running) return instance;
    console.log(`⏳  Waiting RUNNING (${i}/${maxTries})`);
    await new Promise(r => setTimeout(r, delay));
  }
  throw new Error("Timeout waiting for RUNNING state");
}

/*──────── helper → public IP ────────*/
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
    console.log(`⏳  Waiting public IP (${i}/${maxTries})`);
    await new Promise(r => setTimeout(r, delay));
  }
  return null;
}

/*──────────────── 2) CREATE INSTANCE ──────────────────*/
async function createInstance({ imageId, availabilityDomain }) {
  const launch = {
    compartmentId: ORACLE_TENANCY_ID,
    availabilityDomain,
    shape: "VM.Standard.E4.Flex",
    shapeConfig: { ocpus: 1, memoryInGBs: 8 },
    displayName: instanceName,
    sourceDetails: { sourceType: "image", imageId },
    metadata: {
      ssh_authorized_keys: fs.readFileSync(`${process.env.HOME}/.ssh/id_ed25519.pub`, "utf8")
    },
    createVnicDetails: {
      assignPublicIp: true,
      subnetId: await getDefaultSubnet()
    }
  };
  const { instance } = await computeClient.launchInstance({ launchInstanceDetails: launch });
  console.log("Instance OCID →", instance.id);
  return instance;
}

/*──────────────── 3) BOOTSTRAP DOCKER ─────────────────*/
/**
 * Instala Docker + Compose, copia o server‑setup.sh para /tmp
 * e o executa como root.
 *
 * @param {string} ip  IP público da instância.
 * @param {string} [localScript='./server-setup.sh'] Caminho do script local.
 */
function bootstrapDocker(ip, localScript = "./server-setup.sh") {
  const ssh = (cmd, stdio = "inherit") =>
    execSync(`ssh -o StrictHostKeyChecking=no ubuntu@${ip} "${cmd}"`, { stdio });

  // 1) UPDATE → UPGRADE → REBOOT --------------------------------------------
  console.log("🚀 Atualizando sistema + kernel …");
  try {
    ssh(
      // uma única linha protegida por set -e; reboot ao final
      `sudo bash -c 'set -e
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -yq
        apt-get full-upgrade -yq
        apt-get autoremove -yq
        apt-get clean
        reboot'`
    );
  } catch (_) {
    // conexão cai quando o reboot começa: esperado
  }

  // 2) ESPERA O HOST VOLTAR ---------------------------------------------------
  const waitForSSH = () => {
    while (true) {
      try {
        execSync(
          `ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 ubuntu@${ip} "echo ok"`,
          { stdio: "ignore" }
        );
        break; // conexão OK
      } catch {
        console.log("⌛ aguardando host reiniciar …");
        Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 5000); // sleep 5 s
      }
    }
  };
  waitForSSH();
  console.log("✅ Host online novamente.");

  // 3) UPLOAD + EXECUTA SCRIPT -----------------------------------------------
  console.log(`📦 Uploading ${localScript} → /home/ubuntu/server-setup.sh …`);
  execSync(
    `scp -o StrictHostKeyChecking=no ${localScript} ubuntu@${ip}:/home/ubuntu/server-setup.sh`,
    { stdio: "inherit" }
  );

  console.log("🔧 Executando script …");
  ssh("chmod +x ~/server-setup.sh && sudo ~/server-setup.sh");

  console.log("🏁 Provisionamento concluído ✅");
}

/*──────────────── 4) CLOUDFLARE DNS ──────────────────*/
async function createDnsRecord(publicIp) {
  const record = {
    zone_id: 'a4ce24f5629a101be121bd5735fc1a17',
    type: "A",
    name: `${instanceName}.${DOMAIN_NAME}`,
    content: publicIp,
    ttl: 1,
    proxied: true
  };
  console.log(CLOUDFLARE_ZONE_ID);

  const result = await cf.dns.records.create(record);
  console.log("Cloudflare DNS ✔︎ →", result);
}

/*──────────────── PLAYGROUND ─────────────────────────*/
(async () => {
  // Optional: list images first
  await listUbuntuImages();

  const imgId = "ocid1.image.oc1.sa-saopaulo-1.aaaaaaaaizp5gtxmllal26ba7bnjonrjy6au47uqhvwnoanpdhxfcvtklutq";
  const ad = await firstAd();

  const inst = await createInstance({ imageId: imgId, availabilityDomain: ad });
  const run = await waitUntilRunning(inst.id);
  const ip = await fetchPublicIp(run);
  if (!ip) throw new Error("Public IP not available");

  await createDnsRecord(ip);
  
  await new Promise(resolve => { let i = 1; const interval = setInterval(() => { if (i === 15) { clearInterval(interval); resolve(); } console.log(`Esperando ${i++}/15`); }, 1000); });
  bootstrapDocker(ip);
})();
