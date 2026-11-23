// Mozilla's translation engine (bergamot-translator, the Marian models
// Firefox uses), run in a hidden web view Mote owns (MozillaTranslation.swift)
// for the languages macOS can't translate. Files come from Mote over
// `mote-translation://app/files/<hash>`, downloaded and checked by Swift.
// Loaded after Firefox's own `bergamot-translator.js`, which defines
// `loadBergamot`; set up after Firefox's translations-engine.worker.js.

/** The parts of the engine's module this uses. */
interface Bergamot {
  AlignedMemory: new (size: number, alignment: number) => { getByteArrayView(): Uint8Array };
  AlignedMemoryList: new () => { push_back(memory: unknown): void };
  TranslationModel: new (
    source: string,
    target: string,
    config: string,
    model: unknown,
    lex: unknown,
    vocabs: unknown,
    quality: null,
  ) => unknown;
  BlockingService: new (options: { cacheSize: number }) => {
    translate(model: unknown, messages: unknown, options: unknown): Responses;
    translateViaPivoting(first: unknown, second: unknown, messages: unknown, options: unknown): Responses;
  };
  VectorString: new () => { push_back(text: string): void; delete(): void };
  VectorResponseOptions: new () => { push_back(options: object): void; delete(): void };
}

interface Responses {
  size(): number;
  get(index: number): { getTranslatedText(): string };
  delete(): void;
}

/** A model's files by kind ("model", "lex", "vocab", or "srcvocab"/"trgvocab"), each by its hash. */
type Files = Record<string, string>;

declare function loadBergamot(module: object): Bergamot;

/** How each kind of file must sit in the engine's memory. */
const ALIGNMENT: Record<string, number> = { model: 256, lex: 64, vocab: 64, srcvocab: 64, trgvocab: 64 };

let engine: Bergamot | null = null;
let service: InstanceType<Bergamot['BlockingService']> | null = null;
const models = new Map<string, unknown>();

async function file(name: string): Promise<ArrayBuffer> {
  const response = await fetch(`mote-translation://app/files/${encodeURIComponent(name)}`);
  if (!response.ok) throw new Error(`Missing ${name}`);
  return response.arrayBuffer();
}

/** Starts the engine from its WebAssembly, once. */
export async function start(wasm: string): Promise<void> {
  if (engine) return;
  const wasmBinary = await file(wasm);
  engine = await new Promise<Bergamot>((resolve, reject) => {
    const made: Bergamot = loadBergamot({
      // 40 MiB to start, growing as models need: less than starting big.
      INITIAL_MEMORY: 41_943_040,
      wasmBinary,
      print: () => {},
      onAbort: () => reject(new Error('The translation engine could not start.')),
      onRuntimeInitialized: async () => {
        await Promise.resolve();
        resolve(made);
      },
    });
  });
  service = new engine.BlockingService({ cacheSize: 0 });
}

/** The Marian settings Firefox uses, in the shape the engine reads. */
function settings(model: string): string {
  const options: Record<string, string> = {
    'beam-size': '1',
    normalize: '1.0',
    'word-penalty': '0',
    'max-length-break': '128',
    'mini-batch-words': '1024',
    workspace: '128',
    'max-length-factor': '2.0',
    'skip-cost': 'true',
    'cpu-threads': '0',
    quiet: 'true',
    'quiet-translation': 'true',
    'gemm-precision': model.endsWith('intgemm8.bin') ? 'int8shiftAll' : 'int8shiftAlphaAll',
    alignment: 'soft',
  };
  const indent = '            ';
  return `\n${Object.entries(options)
    .map(([key, value]) => `${indent}${key}: ${value}`)
    .join('\n')}\n${indent}`;
}

/** Loads a pair's model from its files, once; its key is "from-to". `model` is the model file's name. */
export async function load(from: string, to: string, files: Files, model: string): Promise<void> {
  const key = `${from}-${to}`;
  if (models.has(key) || !engine) return;
  const kinds = Object.entries(files);
  const read = await Promise.all(kinds.map(([, name]) => file(name)));
  const memory: Record<string, unknown> = {};
  kinds.forEach(([kind], index) => {
    const bytes = new Uint8Array(read[index]!);
    const aligned = new engine!.AlignedMemory(bytes.byteLength, ALIGNMENT[kind] ?? 64);
    aligned.getByteArrayView().set(bytes);
    memory[kind] = aligned;
  });
  const vocabs = new engine.AlignedMemoryList();
  if (memory.vocab) vocabs.push_back(memory.vocab);
  else {
    vocabs.push_back(memory.srcvocab);
    vocabs.push_back(memory.trgvocab);
  }
  models.set(
    key,
    new engine.TranslationModel(from, to, settings(model), memory.model, memory.lex ?? null, vocabs, null),
  );
}

/** Translates texts along `route` (one pair, or two through English); in order. */
export function translate(route: string[], texts: string[]): string[] {
  if (!engine || !service) throw new Error('The translation engine is not running.');
  const steps = route.map((key) => {
    const model = models.get(key);
    if (!model) throw new Error(`No model for ${key}`);
    return model;
  });
  const messages = new engine.VectorString();
  const options = new engine.VectorResponseOptions();
  for (const text of texts) {
    messages.push_back(text);
    options.push_back({ qualityScores: false, alignment: false, html: false });
  }
  let responses: Responses | null = null;
  try {
    responses =
      steps.length === 1
        ? service.translate(steps[0], messages, options)
        : service.translateViaPivoting(steps[0], steps[1], messages, options);
    const out: string[] = [];
    for (let index = 0; index < responses.size(); index++) out.push(responses.get(index).getTranslatedText());
    return out;
  } finally {
    messages.delete();
    options.delete();
    responses?.delete();
  }
}
