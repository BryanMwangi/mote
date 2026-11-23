// Generated from Scripts/src/translation-engine.ts by `pnpm build`. Do not edit.
var moteTranslationEngine = (function(exports) {

Object.defineProperty(exports, Symbol.toStringTag, { value: 'Module' });
//#region src/translation-engine.ts
/** How each kind of file must sit in the engine's memory. */
	const ALIGNMENT = {
		model: 256,
		lex: 64,
		vocab: 64,
		srcvocab: 64,
		trgvocab: 64
	};
	let engine = null;
	let service = null;
	const models = /* @__PURE__ */ new Map();
	async function file(name) {
		const response = await fetch(`mote-translation://app/files/${encodeURIComponent(name)}`);
		if (!response.ok) throw new Error(`Missing ${name}`);
		return response.arrayBuffer();
	}
	/** Starts the engine from its WebAssembly, once. */
	async function start(wasm) {
		if (engine) return;
		const wasmBinary = await file(wasm);
		engine = await new Promise((resolve, reject) => {
			const made = loadBergamot({
				INITIAL_MEMORY: 41943040,
				wasmBinary,
				print: () => {},
				onAbort: () => reject(/* @__PURE__ */ new Error("The translation engine could not start.")),
				onRuntimeInitialized: async () => {
					await Promise.resolve();
					resolve(made);
				}
			});
		});
		service = new engine.BlockingService({ cacheSize: 0 });
	}
	/** The Marian settings Firefox uses, in the shape the engine reads. */
	function settings(model) {
		const options = {
			"beam-size": "1",
			normalize: "1.0",
			"word-penalty": "0",
			"max-length-break": "128",
			"mini-batch-words": "1024",
			workspace: "128",
			"max-length-factor": "2.0",
			"skip-cost": "true",
			"cpu-threads": "0",
			quiet: "true",
			"quiet-translation": "true",
			"gemm-precision": model.endsWith("intgemm8.bin") ? "int8shiftAll" : "int8shiftAlphaAll",
			alignment: "soft"
		};
		const indent = "            ";
		return `\n${Object.entries(options).map(([key, value]) => `${indent}${key}: ${value}`).join("\n")}\n${indent}`;
	}
	/** Loads a pair's model from its files, once; its key is "from-to". `model` is the model file's name. */
	async function load(from, to, files, model) {
		const key = `${from}-${to}`;
		if (models.has(key) || !engine) return;
		const kinds = Object.entries(files);
		const read = await Promise.all(kinds.map(([, name]) => file(name)));
		const memory = {};
		kinds.forEach(([kind], index) => {
			const bytes = new Uint8Array(read[index]);
			const aligned = new engine.AlignedMemory(bytes.byteLength, ALIGNMENT[kind] ?? 64);
			aligned.getByteArrayView().set(bytes);
			memory[kind] = aligned;
		});
		const vocabs = new engine.AlignedMemoryList();
		if (memory.vocab) vocabs.push_back(memory.vocab);
		else {
			vocabs.push_back(memory.srcvocab);
			vocabs.push_back(memory.trgvocab);
		}
		models.set(key, new engine.TranslationModel(from, to, settings(model), memory.model, memory.lex ?? null, vocabs, null));
	}
	/** Translates texts along `route` (one pair, or two through English); in order. */
	function translate(route, texts) {
		if (!engine || !service) throw new Error("The translation engine is not running.");
		const steps = route.map((key) => {
			const model = models.get(key);
			if (!model) throw new Error(`No model for ${key}`);
			return model;
		});
		const messages = new engine.VectorString();
		const options = new engine.VectorResponseOptions();
		for (const text of texts) {
			messages.push_back(text);
			options.push_back({
				qualityScores: false,
				alignment: false,
				html: false
			});
		}
		let responses = null;
		try {
			responses = steps.length === 1 ? service.translate(steps[0], messages, options) : service.translateViaPivoting(steps[0], steps[1], messages, options);
			const out = [];
			for (let index = 0; index < responses.size(); index++) out.push(responses.get(index).getTranslatedText());
			return out;
		} finally {
			messages.delete();
			options.delete();
			responses?.delete();
		}
	}

//#endregion
exports.load = load;
exports.start = start;
exports.translate = translate;
return exports;
})({});