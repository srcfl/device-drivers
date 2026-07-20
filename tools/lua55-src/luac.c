/*
** Minimal Lua compiler (luac) for bytecode generation.
**
** Supports:
**   -o FILE   output to FILE (default: luac.out)
**   -s        strip debug information
**   -p        parse only (syntax check, no output)
**   -v        print version
**   --        stop processing options
**
** This is a simplified version of the standard luac.c, sufficient for
** compiling single Lua source files to bytecode. Used by Sourceful's CI
** to produce bytecode compatible with the ESP32-C3 Zap gateway.
*/

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lua.h"
#include "lauxlib.h"

/* Writer callback for lua_dump — writes bytecode to a FILE* */
static int writer(lua_State *L, const void *p, size_t size, void *ud) {
	(void)L;  /* unused */
	return (fwrite(p, size, 1, (FILE *)ud) != 1) && (size != 0);
}

static void usage(const char *progname) {
	fprintf(stderr,
		"usage: %s [options] [filenames]\n"
		"Available options:\n"
		"  -o FILE  output to FILE (default: luac.out)\n"
		"  -s       strip debug information\n"
		"  -p       parse only (syntax check)\n"
		"  -v       show version information\n"
		"  --       stop handling options\n",
		progname);
}

int main(int argc, char *argv[]) {
	const char *output = "luac.out";
	int strip = 0;
	int parse_only = 0;
	int i;
	lua_State *L;

	/* Parse options */
	for (i = 1; i < argc; i++) {
		if (argv[i][0] != '-')
			break;  /* end of options */
		if (strcmp(argv[i], "--") == 0) {
			i++;
			break;
		}
		else if (strcmp(argv[i], "-o") == 0) {
			if (++i >= argc) {
				fprintf(stderr, "%s: -o requires an argument\n", argv[0]);
				return EXIT_FAILURE;
			}
			output = argv[i];
		}
		else if (strcmp(argv[i], "-s") == 0) {
			strip = 1;
		}
		else if (strcmp(argv[i], "-p") == 0) {
			parse_only = 1;
		}
		else if (strcmp(argv[i], "-v") == 0) {
			printf("%s\n", LUA_RELEASE);
			return EXIT_SUCCESS;
		}
		else {
			fprintf(stderr, "%s: unknown option '%s'\n", argv[0], argv[i]);
			usage(argv[0]);
			return EXIT_FAILURE;
		}
	}

	if (i >= argc) {
		fprintf(stderr, "%s: no input files\n", argv[0]);
		usage(argv[0]);
		return EXIT_FAILURE;
	}

	L = luaL_newstate();
	if (L == NULL) {
		fprintf(stderr, "%s: cannot create Lua state: not enough memory\n", argv[0]);
		return EXIT_FAILURE;
	}

	/* Load and compile each input file */
	for (; i < argc; i++) {
		if (luaL_loadfile(L, argv[i]) != LUA_OK) {
			fprintf(stderr, "%s: %s\n", argv[0], lua_tostring(L, -1));
			lua_close(L);
			return EXIT_FAILURE;
		}
		if (parse_only) {
			lua_pop(L, 1);
			continue;
		}
	}

	if (!parse_only) {
		/* Dump the last loaded chunk to the output file */
		FILE *out = fopen(output, "wb");
		if (out == NULL) {
			fprintf(stderr, "%s: cannot open '%s': %s\n",
				argv[0], output, strerror(errno));
			lua_close(L);
			return EXIT_FAILURE;
		}
		if (lua_dump(L, writer, out, strip) != 0) {
			fprintf(stderr, "%s: error dumping bytecode\n", argv[0]);
			fclose(out);
			lua_close(L);
			return EXIT_FAILURE;
		}
		fclose(out);
	}

	lua_close(L);
	return EXIT_SUCCESS;
}
