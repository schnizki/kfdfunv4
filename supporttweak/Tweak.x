#include <unistd.h>
#include <stdio.h>
#include <dlfcn.h>
#include <spawn.h>
#include <dispatch/dispatch.h>
#include <Foundation/Foundation.h>
#include <dirent.h>
#include <roothide.h>

#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1

int posix_spawnattr_set_persona_np(const posix_spawnattr_t* __restrict, uid_t, uint32_t);
int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t* __restrict, uid_t);
int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t* __restrict, uid_t);

int fd_is_valid(int fd)
{
    return fcntl(fd, F_GETFD) != -1 || errno != EBADF;
}

NSString* getNSStringFromFile(int fd)
{
    NSMutableString* ms = [NSMutableString new];
    ssize_t num_read;
    char c;
    if(!fd_is_valid(fd)) return @"";
    while((num_read = read(fd, &c, sizeof(c))))
    {
        [ms appendString:[NSString stringWithFormat:@"%c", c]];
        if(c == '\n') break;
    }
    return ms.copy;
}

int spawnRoot(NSString* path, NSArray* args, NSString** stdOut, NSString** stdErr)
{
    NSMutableArray* argsM = args.mutableCopy ?: [NSMutableArray new];
    [argsM insertObject:path.lastPathComponent atIndex:0];
    
    NSUInteger argCount = [argsM count];
    char **argsC = (char **)malloc((argCount + 1) * sizeof(char*));

    for (NSUInteger i = 0; i < argCount; i++)
    {
        argsC[i] = strdup([[argsM objectAtIndex:i] UTF8String]);
    }
    argsC[argCount] = NULL;

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);

    posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    posix_spawnattr_set_persona_uid_np(&attr, 0);
    posix_spawnattr_set_persona_gid_np(&attr, 0);

    posix_spawn_file_actions_t action;
    posix_spawn_file_actions_init(&action);

    int outErr[2];
    if(stdErr)
    {
        pipe(outErr);
        posix_spawn_file_actions_adddup2(&action, outErr[1], STDERR_FILENO);
        posix_spawn_file_actions_addclose(&action, outErr[0]);
    }

    int out[2];
    if(stdOut)
    {
        pipe(out);
        posix_spawn_file_actions_adddup2(&action, out[1], STDOUT_FILENO);
        posix_spawn_file_actions_addclose(&action, out[0]);
    }
    
    pid_t task_pid;
    int status = -200;
    int spawnError = posix_spawn(&task_pid, [path UTF8String], &action, &attr, (char* const*)argsC, NULL);
    posix_spawnattr_destroy(&attr);
    for (NSUInteger i = 0; i < argCount; i++)
    {
        free(argsC[i]);
    }
    free(argsC);
    
    if(spawnError != 0)
    {
        NSLog(@"posix_spawn error %d\n", spawnError);
        return spawnError;
    }

    do
    {
        if (waitpid(task_pid, &status, 0) != -1) {
            NSLog(@"Child status %d", WEXITSTATUS(status));
        } else
        {
            perror("waitpid");
            return -222;
        }
    } while (!WIFEXITED(status) && !WIFSIGNALED(status));

    if(stdOut)
    {
        close(out[1]);
        NSString* output = getNSStringFromFile(out[0]);
        *stdOut = output;
    }

    if(stdErr)
    {
        close(outErr[1]);
        NSString* errorOutput = getNSStringFromFile(outErr[0]);
        *stdErr = errorOutput;
    }
    
    return WEXITSTATUS(status);
}

/*%hook NSUserDefaults

- (id)initWithSuiteName:(id)arg1 {
	NSLog(@"[NSUserDefaults initWithSuiteName] called with arg1: %@", arg1);
	if (!arg1) {
		NSLog(@"[NSUserDefaults initWithSuiteName] arg1 is nil");
		return %orig(nil);
	}
	NSArray *blacklist = @[@"me.lau.AtriaPrefs"];
	if ([blacklist containsObject:arg1]) {
		NSLog(@"[NSUserDefaults initWithSuiteName] blocked");
		return %orig(nil);
	}
	return %orig;
}

%end

%hook HBPreferences

- (id)initWithIdentifier:(NSString *)identifier {
	NSLog(@"[HBPreferences initWithIdentifier] called with identifier: %@", identifier);
	if (!identifier) {
		NSLog(@"[HBPreferences initWithIdentifier] identifier is nil");
		return %orig(nil);
	}
	NSArray *blacklist = @[@"me.lau.AtriaPrefs"];
	if ([blacklist containsObject:identifier]) {
		NSLog(@"[HBPreferences initWithIdentifier] blocked");
		return %orig(nil);
	}
	return %orig;
}

+ (id)preferencesForIdentifier:(NSString *)identifier {
	NSLog(@"[HBPreferences preferencesForIdentifier] called with identifier: %@", identifier);
	if (!identifier) {
		NSLog(@"[HBPreferences preferencesForIdentifier] identifier is nil");
		return %orig(nil);
	}
	NSArray *blacklist = @[@"me.lau.AtriaPrefs"];
	if ([blacklist containsObject:identifier]) {
		NSLog(@"[HBPreferences preferencesForIdentifier] blocked");
		return %orig(nil);
	}
	return %orig;
}

%end*/

bool tweak_opened = false;

bool os_variant_has_internal_content(const char* subsystem);
%hookf(bool, os_variant_has_internal_content, const char* subsystem) {
	if (!tweak_opened) {
		NSLog(@"[mineek's supporttweak] loading actual tweaks");
		//NSString *tweakFolderPath = @"/var/jb/Library/MobileSubstrate/DynamicLibraries";
		NSString *tweakFolderPath = jbroot(@"/Library/MobileSubstrate/DynamicLibraries");
		NSFileManager *fileManager = [NSFileManager defaultManager];
		NSArray *tweakFolderContents = [fileManager contentsOfDirectoryAtPath:tweakFolderPath error:nil];
		for (NSString *tweak in tweakFolderContents) {
			if ([tweak hasSuffix:@".dylib"]) {
				NSString *tweakPath = [tweakFolderPath stringByAppendingPathComponent:tweak];
                // check if this tweak is supposed for springboard, by checking the plist, and remove .dylib from the path
                NSString *plistPath = [tweakPath stringByReplacingOccurrencesOfString:@".dylib" withString:@".plist"];
                if ([fileManager fileExistsAtPath:plistPath]) {
                    NSString *plistContents = [NSString stringWithContentsOfFile:plistPath encoding:NSUTF8StringEncoding error:nil];
                    if ([plistContents containsString:@"com.apple.springboard"]) {
                        NSLog(@"[mineek's supporttweak] loading tweak: %@", tweakPath);
				        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
					        void *handle = dlopen([tweakPath UTF8String], RTLD_NOW);
					        if (handle) {
						        NSLog(@"[mineek's supporttweak] loaded tweak");
					        } else {
						        NSLog(@"[mineek's supporttweak] failed to load tweak");
					        }
				        });
                    }
                }
			}
		}
        spawnRoot(jbroot(@"/basebin/bootstrapd"), @[@"daemon",@"-f"], nil, nil);
        //dlopen(jbroot(@"/basebin/bootstrap.dylib").UTF8String, RTLD_GLOBAL | RTLD_NOW);
		tweak_opened = true;
	}
    return true;
}

%hook CSStatusTextView
- (void)setInternalLegalText:(NSString *)string {
    %orig(@"Thank you for using kfdmineek! <3");
}
%end

#define CS_DEBUGGED 0x1000000
int csops(pid_t pid, unsigned int  ops, void * useraddr, size_t usersize);
int fork(void);
int ptrace(int, int, int, int);
int isJITEnabled(void) {
	int flags;
	csops(getpid(), 0, &flags, sizeof(flags));
	return (flags & CS_DEBUGGED) != 0;
}

%ctor {
	NSLog(@"[mineek's supporttweak] loaded");
	if (!isJITEnabled()) {
		NSLog(@"[mineek's supporttweak] JIT not enabled, enabling");
		int pid = fork();
		if (pid == 0) {
			ptrace(0, 0, 0, 0);
			exit(0);
		} else if (pid > 0) {
			while (wait(NULL) > 0) {
				usleep(1000);
			}
		}
	}
}
