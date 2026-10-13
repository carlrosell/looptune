#!/usr/bin/env node
// Generates the oref0 autotune parity fixtures in
// Tests/LoopTuneKitTests/Fixtures/oref0 by running oref0's real autotune core
// (lib/autotune/index.js, tuneAllTheThings) on crafted, pre-categorized
// preppedGlucose inputs. Expected values come only from that run.
//
// See Tests/LoopTuneKitTests/Fixtures/oref0/README.md for how to obtain the
// pinned oref0 revision.
//
// Usage:
//   TZ=UTC node scripts/generate-oref0-fixtures.js --oref0 <clone> [--out <dir>]
//   TZ=UTC node scripts/generate-oref0-fixtures.js --oref0 <clone> --check
//
// --out defaults to the committed fixture directory. --check writes nothing and
// exits 1 unless every generated file is byte-identical to the one in --out.
//
// The core buckets basal deviations with local-time Date#getHours(), so TZ is
// forced to UTC before oref0 is loaded and verified before any scenario runs.
"use strict";

process.env.TZ = "UTC";

const childProcess = require("child_process");
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const OREF0_REVISION = "88cf032aa74ff25f69464a7d9cd601ee3940c0b3";
const FIXTURE_DIR = path.join(
    __dirname,
    "..",
    "Tests",
    "LoopTuneKitTests",
    "Fixtures",
    "oref0"
);

function usage(message) {
    if (message) {
        console.error("error: " + message);
    }
    console.error(
        "usage: TZ=UTC node scripts/generate-oref0-fixtures.js --oref0 <clone> [--out <dir> | --check]"
    );
    process.exit(2);
}

function parseArguments(argv) {
    const options = { oref0: null, out: FIXTURE_DIR, check: false };
    for (let i = 0; i < argv.length; i++) {
        const argument = argv[i];
        if (argument === "--oref0" || argument === "--out") {
            const value = argv[++i];
            if (!value) {
                usage(argument + " requires a path");
            }
            options[argument.slice(2)] = path.resolve(value);
        } else if (argument === "--check") {
            options.check = true;
        } else if (argument === "--help" || argument === "-h") {
            usage();
        } else {
            usage("unknown argument " + argument);
        }
    }
    if (!options.oref0) {
        usage("--oref0 is required");
    }
    return options;
}

function git(directory, args) {
    return childProcess
        .execFileSync("git", ["-C", directory].concat(args), {
            encoding: "utf8",
        })
        .trim();
}

// Refuse to produce an oracle from any other revision or from a modified tree.
function verifyOref0Checkout(directory) {
    let head;
    let status;
    try {
        head = git(directory, ["rev-parse", "HEAD"]);
        status = git(directory, ["status", "--porcelain", "--untracked-files=no"]);
    } catch (error) {
        throw new Error(directory + " is not a readable oref0 git checkout");
    }
    if (head !== OREF0_REVISION) {
        throw new Error(
            "oref0 checkout is at " + head + "; expected " + OREF0_REVISION
        );
    }
    if (status !== "") {
        throw new Error("oref0 checkout has modified tracked files:\n" + status);
    }
}

function verifyUTC() {
    const probe = new Date(Date.UTC(2023, 10, 15, 12, 0, 0));
    if (probe.getTimezoneOffset() !== 0 || probe.getHours() !== 12) {
        throw new Error(
            "local time is not UTC; rerun with TZ=UTC in the environment"
        );
    }
}

// ---------------------------------------------------------------------------
// Profiles (profile.json / pumpprofile.json shape)
// ---------------------------------------------------------------------------

function makeProfile() {
    const basalprofile = [];
    for (let i = 0; i < 24; i++) {
        basalprofile.push({
            i: i,
            minutes: i * 60,
            start: ("000" + i).slice(-2) + ":00:00",
            rate: 1.0,
        });
    }
    return {
        basalprofile: basalprofile,
        isfProfile: {
            sensitivities: [
                { i: 0, offset: 0, sensitivity: 50, start: "00:00:00" },
            ],
            units: "mg/dL",
        },
        sens: 50,
        carb_ratio: 10,
        csf: 5,
        dia: 6,
        curve: "rapid-acting",
        autosens_max: 1.2,
        autosens_min: 0.7,
        min_5m_carbimpact: 8,
        timezone: "UTC",
    };
}

function deepCopy(value) {
    return JSON.parse(JSON.stringify(value));
}

// ---------------------------------------------------------------------------
// Glucose datums in the shape lib/autotune-prep/categorize.js emits:
// deviation and avgDelta are toFixed(2) strings and BGI is a number. All
// datums fall on 2023-11-15 UTC.
// ---------------------------------------------------------------------------

function datum(hour, minute, glucose, bgi, deviation, avgDelta) {
    const date = new Date(Date.UTC(2023, 10, 15, hour, minute, 0));
    return {
        date: date.getTime(),
        dateString: date.toISOString(),
        glucose: glucose,
        BGI: bgi,
        deviation: deviation.toFixed(2),
        avgDelta: avgDelta.toFixed(2),
    };
}

// 20 ISF datums at 14:00-15:35 UTC with deviations 0.80..1.18 in 0.02 steps.
function isfData() {
    const data = [];
    for (let i = 0; i < 20; i++) {
        const hour = 14 + Math.floor((i * 5) / 60);
        const minute = (i * 5) % 60;
        data.push(datum(hour, minute, 150, -4, 0.8 + 0.02 * i, -3.0));
    }
    return data;
}

// 12 basal datums at 12:00-12:55 UTC, each with deviation +6.00.
function positiveBasalData() {
    const data = [];
    for (let i = 0; i < 12; i++) {
        data.push(datum(12, i * 5, 150, -1, 6.0, 2.0));
    }
    return data;
}

// 2 basal datums in hour 3 UTC with deviation -4.00.
function negativeBasalData() {
    return [
        datum(3, 0, 150, -1, -4.0, -1.0),
        datum(3, 5, 150, -1, -4.0, -1.0),
    ];
}

const SCENARIOS = [
    {
        name: "isf_positive",
        prepped: () => ({
            CRData: [],
            CSFGlucoseData: [],
            ISFGlucoseData: isfData(),
            basalGlucoseData: [],
        }),
    },
    {
        name: "basal_positive",
        prepped: () => ({
            CRData: [],
            CSFGlucoseData: [],
            ISFGlucoseData: [],
            basalGlucoseData: positiveBasalData(),
        }),
    },
    {
        name: "mixed",
        prepped: () => ({
            CRData: [],
            CSFGlucoseData: [],
            ISFGlucoseData: isfData(),
            basalGlucoseData: positiveBasalData().concat(negativeBasalData()),
        }),
    },
];

// ---------------------------------------------------------------------------
// Running oref0
// ---------------------------------------------------------------------------

function runScenario(tuneAllTheThings, scenario) {
    // tuneAllTheThings mutates previousAutotune and returns it, so each run
    // gets fresh profiles and the inputs are snapshotted before the call.
    const previousAutotune = makeProfile();
    const pumpProfile = makeProfile();
    const prepped = scenario.prepped();
    const input = {
        isf: previousAutotune.isfProfile.sensitivities[0].sensitivity,
        pumpISF: pumpProfile.isfProfile.sensitivities[0].sensitivity,
        carbRatio: previousAutotune.carb_ratio,
        pumpCarbRatio: pumpProfile.carb_ratio,
        basalHourly: previousAutotune.basalprofile.map((entry) => entry.rate),
        pumpBasalHourly: pumpProfile.basalprofile.map((entry) => entry.rate),
        prepped: deepCopy(prepped),
    };

    const result = tuneAllTheThings({
        previousAutotune: previousAutotune,
        pumpProfile: pumpProfile,
        preppedGlucose: deepCopy(prepped),
    });
    if (!result) {
        throw new Error("oref0 returned no result for " + scenario.name);
    }

    const basalHourly = [];
    const untuned = [];
    for (let hour = 0; hour < 24; hour++) {
        const entry = result.basalprofile[hour];
        if (!entry || entry.i !== hour) {
            throw new Error("unexpected basalprofile order in " + scenario.name);
        }
        basalHourly.push(entry.rate);
        untuned.push(entry.untuned || 0);
    }

    return {
        input: input,
        expected: {
            sens: result.isfProfile.sensitivities[0].sensitivity,
            carb_ratio: result.carb_ratio,
            basalHourly: basalHourly,
            untuned: untuned,
        },
    };
}

// oref0 logs its tuning steps with console.error; keep them out of the output.
function quietly(body) {
    const original = console.error;
    console.error = () => {};
    try {
        return body();
    } finally {
        console.error = original;
    }
}

function sha256(text) {
    return crypto.createHash("sha256").update(text).digest("hex");
}

function main() {
    const options = parseArguments(process.argv.slice(2));
    verifyUTC();
    verifyOref0Checkout(options.oref0);

    const tuneAllTheThings = require(path.join(options.oref0, "lib", "autotune"));
    const files = SCENARIOS.map((scenario) => {
        const fixture = quietly(() => runScenario(tuneAllTheThings, scenario));
        return {
            name: scenario.name + ".json",
            text: JSON.stringify(fixture, null, 2) + "\n",
        };
    });

    if (options.check) {
        let mismatches = 0;
        for (const file of files) {
            const committedPath = path.join(options.out, file.name);
            const committed = fs.existsSync(committedPath)
                ? fs.readFileSync(committedPath, "utf8")
                : null;
            const matches = committed === file.text;
            if (!matches) {
                mismatches += 1;
            }
            console.log((matches ? "match    " : "MISMATCH ") + file.name);
        }
        if (mismatches > 0) {
            console.error(
                mismatches + " fixture(s) differ from oref0 " + OREF0_REVISION
            );
            process.exit(1);
        }
        console.log("all fixtures match oref0 " + OREF0_REVISION);
        return;
    }

    fs.mkdirSync(options.out, { recursive: true });
    for (const file of files) {
        fs.writeFileSync(path.join(options.out, file.name), file.text);
        console.log(sha256(file.text) + "  " + file.name);
    }
}

try {
    main();
} catch (error) {
    console.error("error: " + error.message);
    process.exit(1);
}
