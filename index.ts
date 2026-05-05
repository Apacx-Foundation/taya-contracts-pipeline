import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { z } from "zod";
import { isAddress, type Address } from "viem";

export const UmaConfigSchema = z.object({
  finder: z
    .string()
    .refine(isAddress, { message: "Invalid address" }) as z.ZodType<Address>,
  optimisticOracleV2: z
    .string()
    .refine(isAddress, { message: "Invalid address" }) as z.ZodType<Address>,
});

export const TokensConfigSchema = z.object({
  pht: z
    .string()
    .refine(isAddress, { message: "Invalid address" }) as z.ZodType<Address>,
  usdc: z
    .string()
    .refine(isAddress, { message: "Invalid address" }) as z.ZodType<Address>,
  usdt: z
    .string()
    .refine(isAddress, { message: "Invalid address" }) as z.ZodType<Address>,
});

export const NetworkConfigSchema = z.object({
  admins: z.array(
    z
      .string()
      .refine(isAddress, { message: "Invalid address" }) as z.ZodType<Address>,
  ),
  uma: UmaConfigSchema,
  tokens: TokensConfigSchema,
});

export const DeploymentOutputSchema = z.object({
  ctf: z
    .string()
    .refine(isAddress, { message: "Invalid address" }) as z.ZodType<Address>,
  umaAdapter: z
    .string()
    .refine(isAddress, { message: "Invalid address" }) as z.ZodType<Address>,
  fpmmFactory: z
    .string()
    .refine(isAddress, { message: "Invalid address" }) as z.ZodType<Address>,
  cappedLmsrFactory: z
    .string()
    .refine(isAddress, { message: "Invalid address" }) as z.ZodType<Address>,
  umaAdapterGate: z
    .string()
    .refine(isAddress, { message: "Invalid address" }) as z.ZodType<Address>,
  whitelist: z
    .string()
    .refine(isAddress, { message: "Invalid address" }) as z.ZodType<Address>,
  bettingToken: z
    .string()
    .refine(isAddress, { message: "Invalid address" }) as z.ZodType<Address>,
  fixedMathLib: z
    .string()
    .refine(isAddress, { message: "Invalid address" }) as z.ZodType<Address>,
  // APA-455: retired pattern, kept in JSON as audit trail of historical on-chain
  // deploys. Optional so a fresh-chain bootstrap that never deployed them still
  // validates. Nothing in the runtime code path reads either field.
  delegatecallExecutor: z
    .string()
    .refine(isAddress, { message: "Invalid address" })
    .optional() as z.ZodType<Address | undefined>,
  LMSRBuyExactHelper: z
    .string()
    .refine(isAddress, { message: "Invalid address" })
    .optional() as z.ZodType<Address | undefined>,
  // Set by 20260505-deploy-capped-lmsr-buy-exact.sh: the previous factory address
  // before APA-455 swapped the canonical `cappedLmsrFactory`. Audit trail only.
  cappedLmsrFactoryLegacy: z
    .string()
    .refine(isAddress, { message: "Invalid address" })
    .optional() as z.ZodType<Address | undefined>,
  deployedAtBlock: z.number() as z.ZodType<number>,
});

export type NetworkConfig = z.infer<typeof NetworkConfigSchema>;
export type DeploymentOutput = z.infer<typeof DeploymentOutputSchema>;

export interface ChainBundle {
  chainId: number;
  networkConfig: NetworkConfig;
  deployment: DeploymentOutput;
}

const ROOT_DIR = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
const NETWORKS_DIR = path.join(ROOT_DIR, "config", "networks");
const OUTPUT_DIR = path.join(ROOT_DIR, "script", "output");

export function getNetworkConfig(chainId: number): NetworkConfig {
  const content = readFileSync(
    path.join(NETWORKS_DIR, `${chainId}.json`),
    "utf-8",
  );
  return NetworkConfigSchema.parse(JSON.parse(content));
}

export function getDeploymentOutput(chainId: number): DeploymentOutput {
  const content = readFileSync(
    path.join(OUTPUT_DIR, `${chainId}.json`),
    "utf-8",
  );
  return DeploymentOutputSchema.parse(JSON.parse(content));
}

/**
 * @throws {ZodError | Error} if the chain configuration or deployment output is missing or invalid
 */
export function getChain(chainId: number): ChainBundle {
  const networkConfig = getNetworkConfig(chainId);
  const deployment = getDeploymentOutput(chainId);
  return { chainId, networkConfig, deployment };
}

export default { getNetworkConfig, getDeploymentOutput, getChain };
