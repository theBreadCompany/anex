//
//  main.m
//  anex
//
//  Created by Fabio Mauersberger on 18.05.23.
//

#import <Foundation/Foundation.h>
#import <ScriptingBridge/ScriptingBridge.h>
#import "Notes.h"
#import <zlib.h>
#import <sqlite3.h>
#import <Quartz/PDFKit.h>

#if MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_11
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#endif


#pragma mark helper structs
struct notes_helper {
    // config
    BOOL            createIndices;      // whether to create index files (root, per account and per folder) wip
    BOOL            embedMedia;         // whether to embed media as base64 strings                         done
    BOOL            copyMedia;          // whether to copy the media to the output directory                done
    BOOL            embedStylesheet;    // whether to embed the custom stylesheet                           tests required
    BOOL            exportAsPDF;        // whether to export the pages as PDFs; indices wont be created     wip
    int             pdfWidth;           // width of the PDF pages that only contain text
    int             pdfHeight;          // height of the PDF pages that only contain text
    int             pdfMargin;          // margins around the text
    NSURL           *customStylesheet;  // a custom stylesheet, if wanted                                   tests required
    NSURL           *root;              // the output folder                                                done
    // helper
    NSURL           *parent;            // the group.com.apple.notes folder
    int             notesindex;         // number of current notes
    int             notescount;         // total number of notes
    sqlite3         *notes_db;          // the NoteStore.sqlite
    sqlite3_stmt    *acc_stmt;          // the sqlite statement to fetch account data
    sqlite3_stmt    *att_stmt;          // the sqlite statement to fetch attachment data
    sqlite3_stmt    *pvw_page_stmt;     // the sqlite statement to fetch attachment preview pages
    sqlite3_stmt    *media_stmt;        // the sqlite statement to fetch media files
};

// put prototypes here to be able to show flow of execution (acc -> dir -> note -> attachment, incl. db calls)
#pragma mark main methods - prototypes
void    processAccount          (NotesAccount *account,         struct notes_helper *helper);
void    processFolder           (NotesFolder *folder,           struct notes_helper *helper);
void    processNote             (NotesNote *note,               struct notes_helper *helper);
id      processAttachment       (NotesAttachment *attachment,   struct notes_helper *helper);

#pragma mark helper methods - prototypes
// command stuff
void printHelp(void);
BOOL processArgv(int argc, const char *argv[], struct notes_helper *helper);
// file stuff
BOOL ensureTarget(NSURL *target);
NSString *MIMETypeForURL(NSURL *url);
// database stuff
NSURL *fetchAccountRoot(NotesAccount *account, struct notes_helper *helper);
NSArray<NSURL *> *fetchAttachments(NSInteger noteID, struct notes_helper *helper);
// data stuff
unsigned char *gunzip(unsigned char *buffer, size_t size);
char **findIDs(unsigned char *buffer, size_t size, int *ID_count);
NSData *printHTMLToPDF(NotesNote *note, struct notes_helper *helper);
// info stuff
void printProgress(struct notes_helper *helper);

#pragma mark helper constants
NSString * const defaultCSS;
NSString * const noteTemplate;
//NSString * const folderIndexTemplate;
//NSString * const accountIndexTemplate;
//NSString * const rootIndexTemplate;
NSString * const indexTemplate;

#pragma mark main methods - implementations
int main(int argc, const char * argv[]) {
    
    @autoreleasepool {
        NotesApplication *app = [SBApplication applicationWithBundleIdentifier:@"com.apple.Notes"];
        
        struct notes_helper *helper = malloc(sizeof(struct notes_helper));
        
        if(!processArgv(argc, argv, helper)) {
            printHelp();
            free(helper);
            printf("Exiting...\n");
            return 1;
        }
        
        helper->parent = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:@"group.com.apple.notes"];
        
        helper->notesindex = 0;
        helper->notescount = (int)[[app notes] count];
        
        int db_err = sqlite3_open([[[helper->parent URLByAppendingPathComponent:@"NoteStore.sqlite"] path] cStringUsingEncoding:NSUTF8StringEncoding], &helper->notes_db);
        if(db_err != SQLITE_OK) fprintf(stderr, "Opening NoteStore.sqlite failed, cannot proceed\n!");
        
        const char *acc_query = "SELECT ZIDENTIFIER FROM ZICCLOUDSYNCINGOBJECT WHERE Z_PK = ?";
        int acc_err = sqlite3_prepare(helper->notes_db, acc_query, -1, &helper->acc_stmt, NULL);
        if(acc_err != SQLITE_OK) fprintf(stderr, "Failed to prepare account statement, failed with error %d!\n", acc_err);
        
        const char *att_query = "SELECT ZMERGEABLEDATA1, ZMEDIA FROM ZICCLOUDSYNCINGOBJECT WHERE Z_PK = ?";
        int att_err = sqlite3_prepare(helper->notes_db, att_query, -1, &helper->att_stmt, NULL);
        if(att_err != SQLITE_OK) fprintf(stderr, "Preparing statement for attachment queries failed with %d!\n", att_err);
        
        const char *page_query = "SELECT ZIDENTIFIER, ZTYPEUTI FROM ZICCLOUDSYNCINGOBJECT WHERE ZIDENTIFIER LIKE ? AND (ZSCALEWHENDRAWING = 0 OR ZSCALEWHENDRAWING IS NULL)";
        int page_err = sqlite3_prepare(helper->notes_db, page_query, -1, &helper->pvw_page_stmt, NULL);
        if(page_err != SQLITE_OK) fprintf(stderr, "Preparing statement for page queries failed with %d!\n", page_err);
        
        const char *media_query = "SELECT ZIDENTIFIER, ZFILENAME FROM ZICCLOUDSYNCINGOBJECT WHERE Z_PK IS ?";
        int media_err = sqlite3_prepare(helper->notes_db, media_query, -1, & helper->media_stmt, NULL);
        if(media_err != SQLITE_OK) fprintf(stderr, "Preparing statement for media queries failed with %d!\n", media_err);
        
        if (ensureTarget(helper->root)) {
            NSURL *root_backup = helper->root;
            for(NotesAccount *account in [app accounts]) {
                processAccount(account, helper);
                helper->root = root_backup;
            };
            printf("\n");
        } else {
            return 2;
        }
        
        sqlite3_finalize(helper->acc_stmt);
        sqlite3_finalize(helper->att_stmt);
        sqlite3_finalize(helper->pvw_page_stmt);
        sqlite3_finalize(helper->media_stmt);
        sqlite3_close(helper->notes_db);
        free(helper);
    }
    return 0;
}

void processAccount(NotesAccount *account, struct notes_helper *helper) {
    NSURL *target = [helper->root URLByAppendingPathComponent:[account name] isDirectory:YES];
    if(ensureTarget(target)) {
        printf("Processing account %s.\n", [[account name] cStringUsingEncoding:NSUTF8StringEncoding]);
        helper->root = target;
        NSURL *parentBackup = helper->parent;
        helper->parent = fetchAccountRoot(account, helper);
        for(NotesFolder *folder in [account folders])
            if([[folder container] respondsToSelector:@selector(name)] && [[folder container] valueForKey:@"name"]) processFolder(folder, helper);
        helper->parent = parentBackup;
        [helper->root URLByDeletingLastPathComponent];
    } else {
        printf("Couldn't process account '%s'!\n", [[account name] cStringUsingEncoding:NSUTF8StringEncoding]);
    }
}

void processFolder(NotesFolder *folder, struct notes_helper *helper) {
    helper->root = [helper->root URLByAppendingPathComponent:[folder name] isDirectory:YES];
    if(ensureTarget(helper->root) /*&& ([[folder name] isEqualToString:@"P-Seminar"] || [[folder name] isEqualToString:@"Schule"])*/) {
        for(NotesFolder *subfolder in [folder folders]) processFolder(subfolder, helper);
        for(NotesNote *note in [folder notes]) processNote(note, helper);
    } else {
        printf("Couldn't process folder '%s'!\n", [[folder name] cStringUsingEncoding:NSUTF8StringEncoding]);
    }
    helper->root = [helper->root URLByDeletingLastPathComponent];
}

void processNote(NotesNote *note, struct notes_helper *helper) {
    NSURL *target = [helper->root URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.%@", [note name], helper->exportAsPDF ? @"pdf" : @"html"]];
    // declare output data
    NSData *htmlData;
    if(helper->exportAsPDF) {
        htmlData = printHTMLToPDF(note, helper);
    } else {
        NSMutableString *body = [NSMutableString stringWithString:[note body]];
        NSRange range = [body rangeOfString:@"<div><br><br></div>"];
        NSUInteger att_idx = 0;
        while(range.location != NSNotFound && att_idx < [[note attachments] count]) {
            NSString *content = processAttachment([[note attachments] objectAtIndex:att_idx], helper);
            [body replaceCharactersInRange:range withString:content];
            range = [body rangeOfString:@"<div><br><br></div>"];
            att_idx++;
        }
        
        // the body can be embedded in a standard HTML document, including <styles> and things
        NSString *htmlBody = [NSString stringWithFormat:[NSString stringWithFormat:noteTemplate, helper->customStylesheet && !helper->embedStylesheet ? [NSString stringWithFormat:@"<link rel=\"stylesheet\" type=\"text/css\" href=\"%@\">", [helper->customStylesheet path]] : [NSString stringWithFormat:@"<style>\n%@\n</style>", helper->customStylesheet ? [NSString stringWithContentsOfURL:helper->customStylesheet encoding:NSUTF8StringEncoding error:nil] : defaultCSS]], body];
        
        htmlData = [htmlBody dataUsingEncoding:NSUTF8StringEncoding];
    }
    
    NSError *error;
    if(error) {
        printf("Failed to export note '%s' in folder '%s'!\n", [[note name] cStringUsingEncoding:NSUTF8StringEncoding], [[[note container] name] cStringUsingEncoding:NSUTF8StringEncoding]);
    } else {
        [htmlData writeToURL:target atomically:NO];
    }
    helper->notesindex++;
    printProgress(helper);
}

id processAttachment(NotesAttachment *attachment, struct notes_helper *helper) {
    if([attachment URL]) {
        return [NSString stringWithFormat:@"<a href=%@>%@</a>", [attachment URL], [attachment name]];
    } else {
        // This is where the pain begins; Notes.h has no way to simply get or even copy the file, you need to manually get the file in the group container and either link, copy or embed it
        NSInteger attachmentID = [[[[attachment id] componentsSeparatedByString:@"ICAttachment/p"] lastObject] integerValue];
        NSArray<NSURL *> *targets = fetchAttachments(attachmentID, helper);;
        
        if(helper->exportAsPDF) {
            return targets;
        } else {
            NSMutableString *result = [NSMutableString string];
            for(NSURL __strong *target in targets) {
                NSString *mime = MIMETypeForURL(target);
                if(mime) {
                    if(helper->embedMedia) {
                        [result appendFormat:@"<%@ src=\"%@\">\n", [mime containsString:@"image"] ? @"img" : @"iframe", [NSString stringWithFormat:@"data:%@;base64,%@", mime, [[NSData dataWithContentsOfURL:target] base64EncodedStringWithOptions:0]]];
                    } else {
                        if(helper->copyMedia) {
                            NSURL *newTarget = [helper->root URLByAppendingPathComponent:[target lastPathComponent]];
                            NSError *error;
                            [[NSFileManager defaultManager] copyItemAtURL:target toURL:newTarget error:&error];
                            if(error) {
                                fprintf(stderr, "Failed to copy file to output directory with error: %s. Using old location anyway.\n", [[error localizedRecoverySuggestion] cStringUsingEncoding:NSUTF8StringEncoding]);
                            } else {
                                target = newTarget;
                            }
                        }
                        [result appendFormat:@"<%@ src=\"%@\" type=\"%@\">\n", [mime containsString:@"image"] ? @"img" : @"embed", [target path], mime];
                    }
                } else {
                    printf("Could not find MIME Type for file: %s (%s)\n", [[[target path] stringByRemovingPercentEncoding] cStringUsingEncoding:NSUTF8StringEncoding], [[attachment id] cStringUsingEncoding:NSUTF8StringEncoding]);
                }
            }
            
            if([result length] > 0 && !helper->exportAsPDF) {
                result = [NSMutableString stringWithFormat:
                      @"<div class=\"img-stack-wrapper\">\n\
                            <p>%@</p>\n\
                            <div class=\"img-stack\">\n\
                                %@\n\
                            </div>\n\
                      </div>"
                          , [attachment name], result];
            }
            return result;
        }
    }
}


#pragma mark helper methods - implementations
void printHelp(void) {
    printf("Usage: anex <output-dir> [--create-indices | --embed-media | --copy-media | --as-pdf | --pdf-width <width> | --pdf-height <height> | --pdf-margin <margin> | --embed-media | --custom-stylesheet <file>]\n"
           "\n"
           "<output-dir>        an output directory to write to; will be created if not existing\n"
           "--create-indices    create index files in the output, account and folder directories\n"
           "--embed-media       embed files in the HTML documents, making them portable; do not use with --copy-media\n"
           "--as-pdf            export all notes as PDF; --create-indices will be ignored for now\n"
           "--copy-media        copy files to the output directory; do not use with --embed-media\n"
           "--custom-stylesheet use the custom stylesheet <file>; will be either copied (default) or embedded\n"
           "--embed-stylesheet  embed the stylesheet in each HTML file\n"
           "--pdf-width         the width of the PDF pages that contain text (default: 612 -> dpi: 72)\n"
           "--pdf-height        the height of the PDF pages that contain text (default: 792 -> dpi: 72)\n"
           "--pdf-margin        the margins the PDF should have\n"
           "\n"
           "Please keep in mind that nothing is portable as long as you dont embed anything. Indices use relative paths, "
           "media absolute ones. If you want to archive your notes and delete the stuff in iCloud, you need to use "
           "--embed-media or simply export as PDF with --as-pdf altogether as files the HTMLs are pointing to will not be "
           "there anymore!\n");
}

BOOL processArgv(int argc, const char *argv[], struct notes_helper *helper) {
    
    helper->embedMedia = NO;
    helper->copyMedia = NO;
    helper->embedStylesheet = NO;
    helper->exportAsPDF = NO;
    // Apple defaults
    helper->pdfWidth = 612;
    helper->pdfHeight = 792;
    helper->pdfMargin = 50;
    helper->customStylesheet = nil;
    helper->root = nil;
    helper->parent = nil;
    
    if(argc < 2) {
        //printf("Expecting at least a directory as a parameter!\n");
        return NO;
    }
    for(int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--create-indices")) {
            helper->createIndices = YES;
        } else if(!strcmp(argv[i], "--embed-media")) {
            helper->embedMedia = YES;
        } else if (!strcmp(argv[i], "--copy-media")) {
            helper->copyMedia = YES;
        } else if (!strcmp(argv[i], "--as-pdf")) {
            helper->exportAsPDF = YES;
        } else if (!strcmp(argv[i], "--pdf-width")) {
            if(i+1 >= argc || strncmp(argv[i+1], "--", 2)) {
                fprintf(stderr, "Missing width value!\n");
                return NO;
            }
            long width = strtol(argv[i+1], NULL, 10);
            if(width) {
                helper->pdfWidth = (int)width;
                i++;
            } else {
                fprintf(stderr, "Given width is either 0 or not a number at all!/n");
            }
        } else if (!strcmp(argv[i], "--pdf-height")) {
            if(i+1 >= argc || strncmp(argv[i+1], "--", 2)) {
                fprintf(stderr, "Missing height value!\n");
                return NO;
            }
            long height = strtol(argv[i+1], NULL, 10);
            if(height) {
                helper->pdfHeight = (int)height;
                i++;
            } else {
                fprintf(stderr, "Given height is either 0 or not a number at all!/n");
            }
        } else if (!strcmp(argv[i], "--pdf-margin")) {
            if(i+1 >= argc || strncmp(argv[i+1], "--", 2)) {
                fprintf(stderr, "Missing margin value!\n");
                return NO;
            }
            long margin = strtol(argv[i+1], NULL, 10);
            if(margin) {
                helper->pdfMargin = (int)margin;
                i++;
            } else {
                fprintf(stderr, "Given margin is either 0 or not a number at all!/n");
            }
        } else if (!strcmp(argv[i], "--embed-stylesheet")) {
            helper->embedStylesheet = YES;
        } else if (!strcmp(argv[i], "--custom-stylesheet") && i+1 < argc) {
            if(!strncmp(argv[i+1], "--", 2)) {
                fprintf(stderr, "--custom-stylesheet expects a file!\n");
                return NO;
            }
            NSURL *customStylesheet = [NSURL fileURLWithPath:[NSString stringWithCString:argv[i] encoding:NSUTF8StringEncoding]];
            if(customStylesheet && [[NSFileManager defaultManager] fileExistsAtPath:[customStylesheet path]]) {
                NSError *error;
                NSString *stylesheet = [NSString stringWithContentsOfURL:customStylesheet encoding:NSUTF8StringEncoding error:&error];
                if(error) {
                    fprintf(stderr, "Checking the custom stylesheet failed: %s\n", [[error localizedDescription] cStringUsingEncoding:NSUTF8StringEncoding]);
                    return NO;
                }
                if(![stylesheet containsString:@".img-stack"]) {
                    printf("Warning! Stylesheet does not contain .img-stack CSS which is the class used for images! Continuing anyway...\n");
                }
                helper->customStylesheet = customStylesheet;
            } else {
                fprintf(stderr, "given custom stylesheet at %s does not exist!\n", [[customStylesheet path] cStringUsingEncoding:NSUTF8StringEncoding]);
                return NO;
            }
            i++;
        } else if (!strncmp(argv[i], "--", 2)) {
            printf("Unknown parameter '%s'! Please check for typos.\n", argv[i]);
            return NO;
        } else {
            helper->root = [NSURL fileURLWithPath:[NSString stringWithCString:argv[i] encoding:NSUTF8StringEncoding] isDirectory:YES];
        }
    }
    
    if(helper->embedMedia && helper->copyMedia) {
        fprintf(stderr, "media can only be either embedded or copied the the output directory!\n");
        return NO;
    }
    
    if(helper->embedStylesheet && !helper->customStylesheet) {
        fprintf(stderr, "embedding stylesheet enabled, but stylesheet itself is missing!\n");
        return NO;
    }
    
    if(!helper->exportAsPDF && (helper->pdfWidth || helper->pdfHeight)) {
        fprintf(stderr, "custom PDF dimensions given while not actually exporting to PDF!\n");
        return NO;
    }
    
    return YES;
}

BOOL ensureTarget(NSURL *target) {
    BOOL isDir = NO;
    if(![[NSFileManager defaultManager] fileExistsAtPath:[target path] isDirectory:&isDir] || !isDir) {
        NSError *error;
        [[NSFileManager defaultManager] createDirectoryAtURL:target withIntermediateDirectories:YES attributes:nil error:&error];
        if(error) {
            printf("Failed to create target directory: %s\n", [[error localizedDescription] cStringUsingEncoding:NSUTF8StringEncoding]);
            return NO;
        }
    }
    return YES;
}

NSString *MIMETypeForURL(NSURL *url) {
    // if the UTI stuff is available
    if(@available(macOS 11, *)) {
        // init the UTI pointer to null
        UTType *UTI = nil;
        // point to the UTI of the URL
        [url getResourceValue:&UTI forKey:NSURLContentTypeKey error:nil];
        // return the MIME type that corresponds the the UTI
        return [UTI preferredMIMEType];
    } else { // file extension may be wrong, so only use as a last resort
        CFStringRef cfext = (__bridge CFStringRef)[url pathExtension];
        // get UTI (in string form) from the URL extension
        NSString *UTI = (__bridge_transfer NSString *)(UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, cfext, nil));
        // init MIME type to nil
        NSString *MIMEType = nil;
        // if there is a UTI available
        if(UTI) {
            // get CFString version of the UTI
            CFStringRef cfUTI = (__bridge CFStringRef)UTI;
            // get the MIME type that corresponds to the UTI
            MIMEType = (__bridge_transfer NSString *)UTTypeCopyPreferredTagWithClass(cfUTI, kUTTagClassMIMEType);
            // cleanup
        }
        return MIMEType;
    }
}

NSURL *fetchAccountRoot(NotesAccount *account, struct notes_helper *helper) {
    // get actual account ID
    int ID = [[[[account id] componentsSeparatedByString:@"ICAccount/p"] lastObject] intValue];
    // reset the account query
    sqlite3_reset(helper->acc_stmt);
    // bind the actual account ID to the query
    sqlite3_bind_int(helper->acc_stmt, 1, ID);
    // init identifier pointer to null
    const char *identifier = NULL;
    // if the account query is successfully, point to the identifier entry in the database
    if(sqlite3_step(helper->acc_stmt) == SQLITE_ROW) identifier = (char*)sqlite3_column_text(helper->acc_stmt, 0);
    // return the URL to the account if successfull, null otherwise
    return identifier ? [helper->parent URLByAppendingPathComponent:[NSString stringWithFormat:@"Accounts/%@", [NSString stringWithCString:identifier encoding:NSUTF8StringEncoding]] isDirectory:YES] : NULL;
}

NSArray<NSURL *> *fetchAttachments(NSInteger noteID, struct notes_helper *helper) {
    // init preview array
    NSMutableArray<NSURL *> *previews = [NSMutableArray array];
    // reset the attachment query statement
    sqlite3_reset(helper->att_stmt);
    // bind the note ID given
    sqlite3_bind_int(helper->att_stmt, 1, (int)noteID);
    // if the query executes successfully
    if(sqlite3_step(helper->att_stmt) == SQLITE_ROW) {
        //printf("SQL query suceeded, fetching protobuf blob.\n");
        // acquire the data stored where the IDs are stored
        void *gzip_proto_buf = (void*)sqlite3_column_blob(helper->att_stmt, 0);
        // get the buffer size of that data
        int buf_size = sqlite3_column_bytes(helper->att_stmt, 0);
        // if buffer size < 1, we probably have a PDF
        if(!buf_size) {
            // point to filename from db
            int media_node = sqlite3_column_int(helper->att_stmt, 1);
            // if the filename is not null
            if(media_node) {
                // reset media query
                sqlite3_reset(helper->media_stmt);
                // bind filename to media query
                sqlite3_bind_int(helper->media_stmt, 1, media_node);
                // if media query succeeded
                if(sqlite3_step(helper->media_stmt) == SQLITE_ROW) {
                    // point to the identifier of the media
                    const char *ID = (char*)sqlite3_column_text(helper->media_stmt, 0);
                    // point to the filename of the media
                    const char *fname = (char*)sqlite3_column_text(helper->media_stmt, 1);
                    // create URL to the media and store it in previews
                    [previews addObject:[helper->parent URLByAppendingPathComponent:[NSString stringWithFormat:@"Media/%s/%@", ID, [NSString stringWithCString:fname encoding:NSUTF8StringEncoding]]]];
                } else {
                    printf("Could not find entry in db with ZMEDIA %d!\n", media_node);
                }
            }
            return previews;
        }
        // unzip the data
        unsigned char *proto_buf = gunzip(gzip_proto_buf, buf_size);
        // init the ID count
        int ID_count = 0;
        // get the IDs stored in the unzipped data
        char **IDs = findIDs(proto_buf, buf_size, &ID_count);
        // for every of those IDs
        for(int i = 0; i < ID_count; i++) {
            // reset the page query statement
            sqlite3_reset(helper->pvw_page_stmt);
            // bind the current ID with length 36 to the query
            sqlite3_bind_text(helper->pvw_page_stmt, 1, IDs[i], 38, NULL);
            // init preview string as null
            char *preview = calloc(50 + 1, sizeof(const char));
            // init uti string as null
            char *uti = calloc(30 + 1, sizeof(const char));
            // for every row
            while(sqlite3_step(helper->pvw_page_stmt) == SQLITE_ROW) {
                // store the first column in the preview string (the first round is overwritten, but thats expected as we need the long version as thats the actual file name)
                memcpy((void*)preview, sqlite3_column_text(helper->pvw_page_stmt, 0), sqlite3_column_bytes(helper->pvw_page_stmt, 0));
                // store the second column in the uti string (of course, only if existing, which is only with the first row)
                memcpy((void*)uti, sqlite3_column_text(helper->pvw_page_stmt, 1), sqlite3_column_bytes(helper->pvw_page_stmt, 1));
            }
            // if the preview and uti strings are initialized and not empty; tables do not return a ZTYPEUTI for some reason, so they are skipped automatically
            if(preview && uti && strlen(uti) > 0) {
                // malloc a resulting file name string able to hold the ID + "." + extension corresponding to the UTI
                char *fname = calloc(50 + 1 + 3 + 1, sizeof(char));
                // copy the preview into the filename
                strcat(fname, preview);
                // copy a separating . to the filename
                strcat(fname, ".");
                // copy the fileextension (either png or jpg) to the filename
                strcat(fname, !strcmp(uti, "public.png") ? "png\0" : "jpg\0");
                //printf("Found %s.\n", fname);
                // finally, append the filename as an NSString to the previews array
                [previews addObject:[[helper->parent URLByAppendingPathComponent:@"Previews"] URLByAppendingPathComponent:[NSString stringWithCString:fname encoding:NSUTF8StringEncoding]]];
                //printf("%s %d\n", uti, strcmp(uti, "com.apple.notes.table"));
                //NSLog(@"%@", [[helper->parent URLByAppendingPathComponent:@"Previews"] URLByAppendingPathComponent:[NSString stringWithCString:fname encoding:NSUTF8StringEncoding]]);
                free(fname);
            }
            free(IDs[i]);
            if(preview) free(preview);
            if(uti) free(uti);
        }
        free(IDs);
        free(proto_buf);
    } else {
        fprintf(stderr, "Could not find attachment node for %ld!\n", (long)noteID);
    }
    return previews;
}

unsigned char *gunzip(unsigned char *buffer, size_t size) {
    // https://www.zlib.net/zlib_how.html
    int state;
    z_stream strm;
    // malloc (approx.) enough memory for the output buffer
    unsigned char *out = malloc(size * 2);
    
    strm.zalloc = Z_NULL;
    strm.zfree = Z_NULL;
    strm.opaque = Z_NULL;
    strm.avail_in = (unsigned int)size;
    strm.avail_out = (uint)size * 2;
    strm.next_in = buffer;
    strm.next_out = out;
    state = inflateInit2(&strm, 16+MAX_WBITS);
    
    // if inflating successfully initialized
    if(state == Z_OK) {
        // inflate()
        inflate(&strm, Z_NO_FLUSH);
        //out = realloc(out, strm.avail_out);
    } else {
        // copy state to the buffer
        memcpy(out, &state, sizeof(state));
        //out = realloc(out, 32);
    }
    // cut down the output buffer to its actual size
    return out;
}

char **findIDs(unsigned char *buffer, size_t size, int *ID_count) {
    unsigned int pattern = 606217746;
    const int ID_size = 38;
    char **IDs = NULL;
    int count = 0;
    for(int i = 0; i < size - ID_size; i++) {
        if(!memcmp(buffer + i, &pattern, sizeof(pattern))) {
            count++;
            IDs = realloc(IDs, count * sizeof(char*));
            IDs[count-1] = malloc(ID_size);
            memcpy(IDs[count-1], buffer + i + sizeof(pattern), ID_size);
            memcpy(IDs[count-1] + 36, "%\0", 2);
            //printf("Found ID %s\n", IDs[count-1]);
        }
    }
    *ID_count = count;
    //printf("Found %d IDs\n", count);
    return IDs;
}

NSData *printHTMLToPDF(NotesNote *note, struct notes_helper *helper) {
    //NSLog(@"%@", [note name]);
    
    // replace every attachment with some string that survives getting parsed as NSAttachmentString
    CFUUIDRef cfuuid = CFUUIDCreate(nil);
    CFStringRef cfplaceholder = CFUUIDCreateString(nil, cfuuid);
    NSString *placeholder = (__bridge_transfer NSString*)cfplaceholder;
    //(cfuuid);
    NSMutableString *body = [NSMutableString stringWithString:[note body]];
    NSMutableArray<NSArray<NSURL *> *> *files = [NSMutableArray array];
    NSRange range = [body rangeOfString:@"<div><br><br></div>"];
    NSUInteger att_idx = 0;
    while(range.location != NSNotFound && att_idx < [[note attachments] count]) {
        NSArray *content = processAttachment([[note attachments] objectAtIndex:att_idx], helper);
        if([content count] > 0) {
            [body replaceCharactersInRange:range withString:placeholder];
            [files addObject:content];
            att_idx++;
        } else {
            // I
            if(range.length < [body length]) {
                [body deleteCharactersInRange:range];
            } else {
                range.location = NSNotFound;
            }
        }
        range = [body rangeOfString:@"<div><br><br></div>"];
    }
    
    // integrate the stylesheet
    body = [NSMutableString stringWithString:[NSString stringWithFormat:[NSString stringWithFormat:noteTemplate, helper->customStylesheet && !helper->embedStylesheet ? [NSString stringWithFormat:@"<link rel=\"stylesheet\" type=\"text/css\" href=\"%@\">", [helper->customStylesheet path]] : [NSString stringWithFormat:@"<style>\n%@\n</style>", helper->customStylesheet ? [NSString stringWithContentsOfURL:helper->customStylesheet encoding:NSUTF8StringEncoding error:nil] : defaultCSS]], body]];
    
    NSMutableAttributedString *att = [[NSMutableAttributedString alloc] initWithHTML:[body dataUsingEncoding:NSUTF8StringEncoding] documentAttributes:nil];
    
    NSMutableData *output = [[NSMutableData alloc] init];
    CFMutableDataRef cfoutput = (__bridge CFMutableDataRef)output;
    CGDataConsumerRef consumer = CGDataConsumerCreateWithCFData(cfoutput);
    CGRect pageSize = CGRectMake(0, 0, helper->pdfWidth, helper->pdfHeight);
    CGRect pageBounds = CGRectMake(helper->pdfMargin, helper->pdfMargin, helper->pdfWidth-(2*helper->pdfMargin), helper->pdfHeight-(2*helper->pdfMargin));
    CGContextRef context = CGPDFContextCreate(consumer, &pageSize, nil);
    
    for(int i = 0; i <= att_idx; i++) {
        NSRange placeholderRange = [[att string] rangeOfString:placeholder];
        NSRange textRange = NSMakeRange(0, placeholderRange.location == NSNotFound ? [att length] : placeholderRange.location);
        NSMutableAttributedString *content = [[NSMutableAttributedString alloc] initWithAttributedString:[att attributedSubstringFromRange:textRange]];
    
            while([content length] > 0) {
                CGContextSaveGState(context);
                CGContextBeginPage(context, nil);
                CFAttributedStringRef cfcontent = (__bridge CFAttributedStringRef)content;
                CTFramesetterRef framesetter = CTFramesetterCreateWithAttributedString(cfcontent);
                CGPathRef framepath = CGPathCreateWithRect(pageBounds, nil);
                CTFrameRef frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, [content length]), framepath, nil);
                CTFrameDraw(frame, context);
                CGContextEndPage(context);
                CGContextRestoreGState(context);
                CFRange visibleRange = CTFrameGetVisibleStringRange(frame);
                [content deleteCharactersInRange:NSMakeRange(visibleRange.location, visibleRange.length)];
                CGPathRelease(framepath);
            }
        
        if(placeholderRange.location != NSNotFound && placeholderRange.location) {
            [att deleteCharactersInRange:placeholderRange];
            for(NSURL *file in [files objectAtIndex:i]) {
                CFURLRef cffile = (__bridge CFURLRef)file;
                if([MIMETypeForURL(file) containsString:@"pdf"]) {
                    CGDataProviderRef provider = CGDataProviderCreateWithURL(cffile);
                    CGPDFDocumentRef document = CGPDFDocumentCreateWithProvider(provider);
                    size_t pagecount = CGPDFDocumentGetNumberOfPages(document);
                    CGPDFDocumentRelease(document);
                    for(int p_i = 0; p_i < pagecount; p_i++) {
                        document = CGPDFDocumentCreateWithProvider(provider); // AAAAAA this is the only way to prevent a bug with CGPDFContext that crashes with certain PDF pages
                        CGContextSaveGState(context);
                        CGPDFPageRef page = CGPDFDocumentGetPage(document, p_i);
                        if(page) {
                            CGRect contentRect = CGPDFPageGetBoxRect(page, kCGPDFMediaBox);
                            CGContextBeginPage(context, &contentRect);
                            CGContextDrawPDFPage(context, page);
                            CGContextEndPage(context);
                            CGContextRestoreGState(context);
                            
                        }
                        
                    }
                } else {
                    CGContextSaveGState(context);
                    CGImageSourceRef source = CGImageSourceCreateWithURL(cffile, nil);
                    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, nil);
                    CGRect contentRect = CGRectMake(0, 0, CGImageGetWidth(image), CGImageGetHeight(image));
                    CGContextBeginPage(context, &contentRect);
                    CGContextDrawImage(context, contentRect, image);
                    CGContextEndPage(context);
                    CGContextRestoreGState(context);
                    
                }
            }
        }
        [att deleteCharactersInRange:textRange];
    }
    
    CGPDFContextClose(context);
    
    
    return output;
}

void printProgress(struct notes_helper *helper) {
    //\x1B[1A\x1B[K ANSI sequence to do basically the same; Swifts print() does not apply \r, so use this instead
    printf("Exporting note %03d of %d\r", helper->notesindex, helper->notescount);
    fflush(stdout);
}


NSString * const defaultCSS =
@"\
body {\n\
    font-family: Helvetica Neue, Helvetica, Arial, sans-serif;\n\
    padding: 2em 2em;\n\
    color: #464646;\n\
    background-color: white;\n\
}\n\
ul.header {\n\
    list-style-type: none;\n\
    margin: 0;\n\
    padding: 0;\n\
    overflow: hidden;\n\
    background-color: #EBEAEF;\n\
    position: fixed;\n\
    top: 0;\n\
    width: 100%;\n\
}\n\
p.header {\n\
    padding: 2em;\n\
    color: #6D6D6D;\n\
}\n\
embed {\n\
    height: 20em;\n\
    margin: 5%;\n\
    display: flex;\n\
}\n\
.img-stack-wrapper {\n\
  background-color: #E2E2E2;\n\
  border: 10px solid #E2E2E2;\n\
  border-radius: 17.5px;\n\
  margin: 10px;\n\
  display: table;\n\
  overflow: auto;\n\
}\n\
.img-stack-wrapper p {\n\
  padding-left: 10px;\n\
  margin-top: 5px;\n\
  margin-bottom: 0px;\n\
}\n\
.img-stack {\n\
  display: flex;\n\
}\n\
.img-stack img {\n\
  margin: 10px;\n\
  height: 20em;\n\
  max-width: 100%%;\n\
}\n\
.img-stack img:hover {\n\
  position: fixed;\n\
  top: 0;\n\
  left: 0;\n\
  right: 0;\n\
  margin: auto;\n\
  max-height: 1000px;\n\
  height: 100%%;\n\
  width: auto;\n\
}\n\
.img-stack embed:hover {\n\
  height: 80vh;\n\
  width: 50vw;\n\
}\n\
@media print {\n\
  html, body {\n\
    width: 210mm;\n\
    height: 297mm;\n\
    margin: 0;\n\
    padding: 0;\n\
  }\n\
  table {page-break-inside: avoid;}\n\
  img {\n\
    max-width: 100%;\n\
    height: auto;\n\
    page-break-inside: avoid;\n\
  }\n\
}\n\
";

// note the UTF-8 meta, only Safari(views) explicitly require it; chrome(alikes) seem to parse HTML as UTF8 by default
NSString * const noteTemplate =
@"\
<html>\n\
    <head>\n\
        <meta charset=\"UTF-8\">\n\
        %@\n\
    </head>\n\
    <body>\n\
        %%@\n\
    </body>\n\
</html>\n\
";

//NSString * const folderIndexTemplate =
NSString * const indexTemplate =
@"\
<html>\n\
    <head>\n\
        %@\
    </head>\n\
    <body>\n\
        \n\
        %%@\n\
    </body>\n\
</html>\n\
";
