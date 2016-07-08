//
//  HTTPDataRequest.m
//  HTTPDataRequest
//
//  Created by yosemite on 16/5/9.
//  Copyright © 2016年 organization. All rights reserved.
//

#import "HTTPDataRequest.h"
#include <iostream>
#include <string>
#include <unordered_map>
#include <map>
#include <deque>
#include <vector>
#include <list>
#include <sys/stat.h>
#include <dirent.h>
#include "leveldb/db.h"

class CacheDirectory {
public:
    NSString *diskCacheDir = nil;
    CacheDirectory() {
        diskCacheDir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"INETTMP"];
    }
} directory;

class LeveldbManager {
private:
    leveldb::DB *db;
    leveldb::Options options;
    leveldb::ReadOptions readOptions;
    leveldb::WriteOptions writeOptions;
    std::string dbFolder;
public:
    LeveldbManager() {
        options.create_if_missing = true;
        options.error_if_exists = false;
        dbFolder = std::string([directory.diskCacheDir UTF8String]);
        leveldb::Status status = leveldb::DB::Open(options, dbFolder, &db);
        if (!status.ok()) {
            //what should be done...
        }
    }
    ~LeveldbManager() {
        if (db != nullptr) {
            delete db;
            db = nullptr;
        }
    }
    ssize_t getFileSize(const char *path) {
        ssize_t fileSize = -1;
        struct stat statBuf;
        if (stat(path, &statBuf) == 0) {
            fileSize = ssize_t(statBuf.st_size);
        }
        return fileSize;
    }
    bool insert(std::string &key, std::string &path) {
        ssize_t fileSize = getFileSize(path.c_str());
        if (fileSize != -1) {
            int fd = open(path.c_str(), O_RDONLY);
            if (fd == -1) {
                return false;
            }
            void *buffer = malloc(fileSize + 8);
            size_t readSize = read(fd, buffer, fileSize);
            if (fileSize != readSize) {
                free(buffer);
                return false;
            }
            leveldb::Slice dbKey(key);
            leveldb::Slice dbValue(static_cast<const char *>(buffer), fileSize);
            leveldb::Status status = db->Put(writeOptions, dbKey, dbValue);
            if (!status.ok()) {
                free(buffer);
                return false;
            }
            free(buffer);
        }
        return true;
    }
    void removeDirectory(const char *dirPath) {
        size_t dirPathLen = strlen(dirPath);
        char filePath[dirPathLen + 32];
        memcpy(filePath, (const void *)dirPath, dirPathLen);
        if (dirPath[dirPathLen - 1] != '/') {
            memcpy(filePath + dirPathLen, "/", 1);
            dirPathLen += 1;
        }
        DIR *const pDIR = opendir(dirPath);
        struct dirent *pdirent = nullptr;
        while ((pdirent = readdir(pDIR))) {
            memset(filePath + dirPathLen, '\0', sizeof filePath - dirPathLen);
            strcat(filePath + dirPathLen, pdirent->d_name);
            remove(filePath);
        }
        rmdir(dbFolder.c_str());
    }
    void clear() {
        delete db;
        removeDirectory(dbFolder.c_str());
        leveldb::Status status = leveldb::DB::Open(options, dbFolder, &db);
        if (!status.ok()) {
            //what should be done...
        }
    }
    std::string find(std::string &key) {
        leveldb::Slice dbKey(key);
        std::string value;
        leveldb::Status status = db->Get(readOptions, dbKey, &value);
        if (status.IsNotFound()) {
            return std::move(value);
        }
        return std::move(value);
    }
};

class MemoryCacheManager {
public:
    using MemMapType = std::map<std::string, std::string>;
private:
    MemMapType cacheMap;
    std::list<std::string *> sequenceList;
    std::size_t allocatedMemSize;
    std::size_t sizeUpperLimit = 10 * 1024 * 1024;
    std::string nullMem;
public:
    std::pair<MemMapType::iterator, bool> insert(std::string key, const void *mem, size_t size) {
        MemMapType::iterator &&iterator = cacheMap.find(key);
        if (iterator != cacheMap.end()) {
            const std::string &valueString = iterator->second;
            if (valueString.size() != 0) {
                allocatedMemSize -= valueString.size();
            }
            allocatedMemSize += size;
            valueString = std::string(static_cast<const std::string::value_type *>(mem), size);
            limit();
            return std::make_pair(iterator, true);
        }
        else {
            auto &&result = cacheMap.emplace(key, std::string(static_cast<const std::string::value_type *>(mem), size));
            if (result.second == true) {
                const std::string &mb = result.first->second;
                sequenceList.emplace_back(&mb);
                allocatedMemSize += mb.size();
                limit();
            }
            return std::move(result);
        }
    }
    void erase(std::string key) {
        MemMapType::iterator &&iterator = cacheMap.find(key);
        if (iterator != cacheMap.end()) {
            for (std::list<std::string *>::iterator ite = sequenceList.begin(); ite != sequenceList.end(); ite++) {
                if (*ite == &(iterator->second)) {
                    sequenceList.erase(ite);
                    break;
                }
            }
            allocatedMemSize -= iterator->second.size();
            cacheMap.erase(iterator);
        }
    }
    void clear() {
        cacheMap.clear();
        sequenceList.clear();
        allocatedMemSize = 0;
    }
    void limit() {
        while (allocatedMemSize > sizeUpperLimit) {
            allocatedMemSize -= (*(sequenceList.begin()))->size();
            (*sequenceList.front()).clear();
            sequenceList.pop_front();
        }
    }
    const std::string &find(std::string &key) {
        MemMapType::iterator &&iterator = cacheMap.find(key);
        if (iterator == cacheMap.end()) {
            nullMem.clear();
            return nullMem;
        }
        else {
            const std::string &valueString = iterator->second;
            for (std::list<std::string *>::iterator ite = sequenceList.begin(); ite != sequenceList.end(); ite++) {
                if (*ite == &valueString) {
                    sequenceList.erase(ite);
                    break;
                }
            }
            sequenceList.emplace_back(&valueString);
            return valueString;
        }
    }
};

class CacheManager : public LeveldbManager, public MemoryCacheManager {
public:
    void insert(NSString *URLString, NSData *data, NSString *filePath) {
        std::string key([URLString UTF8String]);
        std::string fp([filePath UTF8String]);
        if (filePath) {
            LeveldbManager::insert(key, fp);
        }
        if (data) {
            MemoryCacheManager::insert(key, [data bytes], [data length]);
        }
    }
    NSData *find(NSString *URLString) {
        std::string key([URLString UTF8String]);
        const std::string &mmVal = MemoryCacheManager::find(key);
        if (mmVal.size() != 0) {
            NSData *data = [NSData dataWithBytes:mmVal.data() length:mmVal.size()];
            return data;
        }
        else {
            std::string &&dbVal = LeveldbManager::find(key);
            if (dbVal.data() && dbVal.size() != 0) {
                NSData *data = [NSData dataWithBytes:dbVal.data() length:dbVal.size()];
                if ([data length] != 0) {
                    MemoryCacheManager::insert(key, [data bytes], [data length]);
                }
                return data;
            }
        }
        return nil;
    }
    void clear() {
        MemoryCacheManager::clear();
        LeveldbManager::clear();
    }
} cacheManager;

struct PackagedBlock {
    void (__strong ^completion)(NSData *);
    void (__strong ^failure)(NSError *);
    PackagedBlock(void (__autoreleasing ^completion)(NSData *), void (__autoreleasing ^failure)(NSError *)) {
        this->completion = completion;
        this->failure = failure;
    }
    PackagedBlock(const PackagedBlock &obj) {
        this->completion = obj.completion;
        this->failure = obj.failure;
    }
    PackagedBlock(PackagedBlock &&obj) {
        this->completion = obj.completion;
        this->failure = obj.failure;
    }
    PackagedBlock &operator=(const PackagedBlock &obj) {
        this->completion = obj.completion;
        this->failure = obj.failure;
        return *this;
    }
    PackagedBlock &operator=(PackagedBlock &&obj) {
        this->completion = obj.completion;
        this->failure = obj.failure;
        return *this;
    }
    void performCompletion(NSData *data) {
        this->completion(data);
    }
    void performFailure(NSError *error) {
        this->failure(error);
    }
};

struct Task {
    std::deque<PackagedBlock> completionQueue;
    std::deque<PackagedBlock> failureQueue;
    NSURLSessionDownloadTask *__weak downloadTask = nullptr;
    typename std::hash<std::string>::result_type URLHash = 0;
    Task() {
        
    }
    Task(NSURLSessionDownloadTask *downloadTask, typename std::hash<std::string>::result_type URLHash) : downloadTask(downloadTask), URLHash(URLHash) {
        
    }
    Task(const Task &obj) {
        this->completionQueue = obj.completionQueue;
        this->failureQueue = obj.failureQueue;
        this->downloadTask = obj.downloadTask;
        this->URLHash = obj.URLHash;
    }
    Task(Task &&obj) {
        this->completionQueue = std::move(obj.completionQueue);
        this->failureQueue = std::move(obj.failureQueue);
        this->downloadTask = std::move(obj.downloadTask);
        this->URLHash = std::move(obj.URLHash);
    }
    Task &operator=(const Task &obj) {
        this->completionQueue = obj.completionQueue;
        this->failureQueue = obj.failureQueue;
        this->downloadTask = obj.downloadTask;
        this->URLHash = obj.URLHash;
        return *this;
    }
    Task &operator=(Task &&obj) {
        this->completionQueue = std::move(obj.completionQueue);
        this->failureQueue = std::move(obj.failureQueue);
        this->downloadTask = std::move(obj.downloadTask);
        this->URLHash = std::move(obj.URLHash);
        return *this;
    }
    bool operator==(Task &obj) {
        return this->URLHash == obj.URLHash;
    }
    bool operator!=(Task &obj) {
        return this->URLHash != obj.URLHash;
    }
};

class TaskMnager {
    std::map<std::string, Task> taskMap;
public:
    Task nullTask;
    void insert(std::string &key, Task &value) {
        taskMap.insert(std::map<std::string, Task>::value_type(key, value));
    }
    void insert(std::string &&key, Task &&value) {
        taskMap.emplace(std::move(key), std::move(value));
    }
    std::map<std::string, Task>::size_type erase(std::string &key) {
        return taskMap.erase(key);
    }
    void clear() {
        taskMap.clear();
    }
    Task &find(std::string &key) {
        std::map<std::string, Task>::iterator iterator = taskMap.find(key);
        if (iterator != taskMap.end()) {
            return iterator->second;
        }
        else {
            nullTask.downloadTask = nullptr;
            nullTask.URLHash = 0;
            return nullTask;
        }
    }
} taskManager;

@interface HTTPDataRequest ()
@property (nullable, readonly, copy) NSURLRequest  *originalRequest;  /* may be nil if this is a stream task */
@property (nullable, readonly, copy) NSURLRequest  *currentRequest;   /* may differ from originalRequest due to http server redirection */
@property (nullable, readonly, copy) NSURL *location;
@property (nullable, readonly, copy) NSURLResponse *response;
@property (nullable, readonly) NSError *error;
@end

@implementation HTTPDataRequest

#define DEFAULT_FILE_MANAGER [NSFileManager defaultManager]

- (instancetype)initWithOriginalRequest:(NSURLRequest *)originalRequest currentRequest:(NSURLRequest *)currentRequest temporaryFileLocation:(NSURL *)location HTTPResponse:(NSURLResponse *)response requestError:(NSError *)error {
    if (self = [super init]) {
        _originalRequest = originalRequest;
        _currentRequest = currentRequest;
        _location = location;
        _response = response;
        _error = error;
    }
    return self;
}

- (void)taskResultDispatch {
    NSString *URLString = [[[self originalRequest] URL] absoluteString];
    std::string url_string([URLString UTF8String]);
    Task comTask = std::move(taskManager.find(url_string));
    taskManager.erase(url_string);
    if (comTask.downloadTask == nullptr || comTask.URLHash == 0) {
        return;
    }
    if (![self error]) {
        NSData *data = [NSData dataWithContentsOfURL:[self location]];
        cacheManager.insert(URLString, data, [[self location] resourceSpecifier]);
        std::for_each(comTask.completionQueue.begin(), comTask.completionQueue.end(), std::bind2nd(std::mem_fun_ref(&PackagedBlock::performCompletion), data));
    }
    else {
        NSError *error = [self error];
        std::for_each(comTask.failureQueue.begin(), comTask.failureQueue.end(), std::bind2nd(std::mem_fun_ref(&PackagedBlock::performFailure), error));
    }
}

void networkReceivedDataDispatch(void *context) {
    HTTPDataRequest *obj = (__bridge_transfer HTTPDataRequest *)context;
    NSString *URLString = [[[obj originalRequest] URL] absoluteString];
    std::string url_string([URLString UTF8String]);
    Task comTask = std::move(taskManager.find(url_string));
    taskManager.erase(url_string);
    if (comTask.downloadTask == nullptr || comTask.URLHash == 0) {
        return;
    }
    if (![obj error]) {
        NSData *data = [NSData dataWithContentsOfURL:[obj location]];
        cacheManager.insert(URLString, data, [[obj location] resourceSpecifier]);
        std::for_each(comTask.completionQueue.begin(), comTask.completionQueue.end(), std::bind2nd(std::mem_fun_ref(&PackagedBlock::performCompletion), data));
    }
    else {
        NSError *error = [obj error];
        std::for_each(comTask.failureQueue.begin(), comTask.failureQueue.end(), std::bind2nd(std::mem_fun_ref(&PackagedBlock::performFailure), error));
    }
}

+ (BOOL)startTaskWithURLString:(NSString * __autoreleasing)URLString completion:(void (__autoreleasing^)(NSData * __autoreleasing))completion failure:(void (__autoreleasing^)(NSError * __autoreleasing))failure {
    if ([URLString length] < 8) {
        return NO;
    }
    URLString = [URLString stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLFragmentAllowedCharacterSet]];
    NSData *cacheData = cacheManager.find(URLString);
    if (cacheData) {
        completion(cacheData);
        return YES;
    }
    std::string key([URLString UTF8String]);
    Task &task = taskManager.find(key);
    if (task.downloadTask == nullptr || task.URLHash == 0) {
        NSURLRequest *request = [[NSURLRequest alloc] initWithURL:[NSURL URLWithString:URLString]];
        NSURLSessionDownloadTask *downloadTask = [[NSURLSession sharedSession] downloadTaskWithRequest:request completionHandler:^(NSURL * _Nullable location, NSURLResponse * _Nullable response, NSError * _Nullable error) {
            HTTPDataRequest *performer = [[self alloc] initWithOriginalRequest:request currentRequest:nil temporaryFileLocation:location HTTPResponse:response requestError:error];
            //[performer performSelectorOnMainThread:@selector(taskResultDispatch) withObject:nil waitUntilDone:YES];
            dispatch_sync_f(dispatch_get_main_queue(), (__bridge_retained void *)performer, networkReceivedDataDispatch);
        }];
        std::hash<std::string>::result_type URLHash = std::hash<std::string>()(key);
        Task createTask(downloadTask, URLHash);
        createTask.completionQueue.emplace_back(PackagedBlock(completion, failure));
        createTask.failureQueue.emplace_back(PackagedBlock(completion, failure));
        taskManager.insert(std::move(key), std::move(createTask));
        [downloadTask resume];
    }
    else {
        task.completionQueue.emplace_back(PackagedBlock(completion, failure));
        task.failureQueue.emplace_back(PackagedBlock(completion, failure));
    }
    return YES;
}

+ (void)cancelTaskWithURLString:(NSString * __autoreleasing)URLString completion:(void (__autoreleasing ^)(NSInteger))completion {
    std::string key([URLString UTF8String]);
    Task &task = taskManager.find(key);
    if (task.downloadTask == nullptr || task.URLHash == 0) {
        if (completion) {
            completion(0);
        }
    }
    else {
        [task.downloadTask cancel];
        if (completion) {
            completion(1);
        }
    }
}

+ (void)emptyCache {
    taskManager.clear();
    cacheManager.clear();
}

+ (NSUInteger)sizeOfCacheFile {
    NSUInteger calculatedSize = 0;
    NSArray<NSString *> *subpaths = [DEFAULT_FILE_MANAGER subpathsAtPath:directory.diskCacheDir];
    for (NSString *fileName in subpaths) {
        NSDictionary *fileDictionary = [DEFAULT_FILE_MANAGER attributesOfItemAtPath:[directory.diskCacheDir stringByAppendingPathComponent:fileName] error:nil];
        NSNumber *sizeNumber = [fileDictionary objectForKey:NSFileSize];
        calculatedSize += [sizeNumber unsignedIntegerValue];
    }
    return calculatedSize;
}

@end
