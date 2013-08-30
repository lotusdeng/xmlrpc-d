/*
 * XMLRPC server
 * Pavel Kirienko, 2013 (pavel.kirienko@gmail.com)
 */

module xmlrpc.server;

import xmlrpc.encoder : encodeResponse;
import xmlrpc.decoder : decodeCall;
import xmlrpc.data : MethodCallData, MethodResponseData;
import xmlrpc.paramconv : paramsToVariantArray, variantArrayToParams;
import xmlrpc.error : XmlRpcException, MethodFaultException, FciFaultCodes, makeFaultValue;
import std.exception : enforce;
import std.variant : Variant;
import std.string : format;
import std.stdio : writefln, write;
import std.traits : isCallable, ParameterTypeTuple, ReturnType;

alias void delegate(string) LogHandler;
alias Variant[] delegate(Variant[]) RawMethodHandler;

class Server
{
    this(LogHandler logHandler = null, bool addIntrospectionMethods = false)
    {
        if (!logHandler)
            logHandler = (string msg) { write(msg); };
        logHandler_ = logHandler;
        addSystemMethods(this);
    }
    
    string handleRequest(string encodedRequest)
    {
        try
        {
            // Decode the request
            MethodCallData callData;
            try
                callData = decodeCall(encodedRequest);
            catch (Exception ex)
                throw new MethodFaultException(ex.msg, FciFaultCodes.serverErrorInvalidXmlRpc);
            debug (xmlrpc)
                writefln("server <== %s", callData.toString());
            
            MethodResponseData responseData = callMethod(callData);
            
            // Encode the response
            debug (xmlrpc)
                writefln("server ==> %s", responseData.toString());
            return encodeResponse(responseData);
        }
        catch (MethodFaultException ex)
        {
            tryLog("Method fault: %s", ex.msg);
            MethodResponseData responseData;
            responseData.fault = true;
            responseData.params ~= ex.value;
            return encodeResponse(responseData);
        }
        catch (Exception ex)
        {
            tryLog("Server exception: %s", ex);
            MethodResponseData responseData;
            responseData.fault = true;
            responseData.params ~= makeFaultValue(ex.msg, FciFaultCodes.serverErrorInternalXmlRpcError);
            return encodeResponse(responseData);
        }
    }
    
    void addRawMethod(RawMethodHandler handler, string name, string help = "", string[][] signatures = null)
    {
        enforce(name.length, new XmlRpcException("Method name must not be empty"));
        if (name in methods_)
            throw new MethodExistsException(name);
        methods_[name] = MethodInfo(handler, help, signatures);
        debug (xmlrpc)
            writefln("New method: %s; Help: '%s'; Signatures: %s", name, help, signatures);
    }
    
    nothrow bool removeMethod(string name)
    {
        return methods_.remove(name);
    }
    
    @property void logHandler(LogHandler lh) { logHandler_ = lh; }
    @property nothrow LogHandler logHandler() { return logHandler_; }
    
private:
    MethodResponseData callMethod(MethodCallData callData)
    {
        const methodInfoPtr = callData.name in methods_;
        if (methodInfoPtr is null)
        {
            const msg = "Unknown method: " ~ callData.name;
            throw new MethodFaultException(msg, FciFaultCodes.serverErrorMethodNotFound);
        }
        enforce(methodInfoPtr.handler != null, new XmlRpcException("Impossible happens!"));
        try
        {
            MethodResponseData responseData;
            responseData.params = methodInfoPtr.handler(callData.params);
            return responseData;
        }
        catch (MethodFaultException ex)
        {
            throw ex;
        }
        catch (Exception ex)
        {
            const msg = format("%s:%s: %s: %s", ex.file, ex.line, typeid(ex), ex.msg);
            throw new MethodFaultException(msg, FciFaultCodes.applicationError);
        }
    }
    
    nothrow void tryLog(S...)(string fmt, S s)
    {
        if (logHandler_ is null)
            return;
        try
            logHandler_(format(fmt, s) ~ "\n");
        catch (Exception ex)
        {
            debug (xmlrpc)
            {
                try writefln("Log handler exception: %s", ex);
                catch (Exception) { }
            }
        }
    }
    
    static struct MethodInfo
    {
        RawMethodHandler handler;
        string help;
        string[][] signatures;
    }
    
    LogHandler logHandler_;
    MethodInfo[string] methods_;
}

class MethodExistsException : XmlRpcException
{
    private this(string methodName)
    {
        this.methodName = methodName;
        super("Method already exists: " ~ methodName);
    }
    
    string methodName;
}

/**
 * We can't use member function here because that doesn't work with local handlers:
 * Error: template instance addMethod!(method) cannot use local 'method' as parameter to non-global template <...>
 */
void addMethod(alias method, string name = __traits(identifier, method))(Server server, string help = "",
                                                                         string[][] signatures = null)
{
    static assert(name.length, "Method name must not be empty");
    auto handler = makeRawMethod!method();
    server.addRawMethod(handler, name, help, signatures);
}

private:

/**
 * Takes anything callable at compile-time, returns delegate that conforms RawMethodHandler type.
 * The code that converts XML-RPC types into the native types and back will be generated at compile time.
 */
RawMethodHandler makeRawMethod(alias method)()
{
    static assert(isCallable!method, "Method handler must be callable");
    
    alias ParameterTypeTuple!method Input;
    alias ReturnType!method Output;
    
    auto tryVariantArrayToParams(Args...)(Variant[] variants)
    {
        try
            return variantArrayToParams!(Args)(variants);
        catch (Exception ex)
            throw new MethodFaultException(ex.msg, FciFaultCodes.serverErrorInvalidMethodParams);
    }
    
    return (Variant[] inputVariant)  // Well, the life is getting tough now.
    {
        // Input resolution
        static if (Input.length == 0)
        {
            enforce(inputVariant.length == 0,
                new MethodFaultException("Method expects no arguments", FciFaultCodes.serverErrorInvalidMethodParams));
            
            static if (is(Output == void))
            {
                method();
            }
            else
            {
                Output output = method();
            }
        }
        else
        {
            Input input = tryVariantArrayToParams!(Input)(inputVariant);
            static if (is(Output == void))
            {
                method(input);
            }
            else
            {
                Output output = method(input);
            }
        }
        // Output resolution
        static if (is(Output == void))
        {
            Variant[] dummy;
            return dummy;
        }
        else static if (is(typeof( paramsToVariantArray(output.expand) )))
        {
            return paramsToVariantArray(output.expand);
        }
        else
        {
            return paramsToVariantArray(output);
        }
    };
}

void addSystemMethods(Server server)
{
    Server.MethodInfo* findMethod(string methodName)
    {
        auto infoPtr = methodName in server.methods_;
        const msg = "No such method: " ~ methodName;
        enforce(infoPtr, new MethodFaultException(msg, -1));
        return infoPtr;
    }
    
    string[] listMethods() { return server.methods_.keys(); }
    server.addMethod!(listMethods, "system.listMethods")();
    
    string methodHelp(string name) { return findMethod(name).help; }
    server.addMethod!(methodHelp, "system.methodHelp")();
    
    Variant methodSignature(string name)              // This one is tricky
    {
        auto signatures = findMethod(name).signatures;
        if (signatures.length == 0)
            return Variant("undef");                  // Return type is computed at runtime
        Variant[] variantSignatures;
        variantSignatures.length = signatures.length;
        foreach (signIndex, sign; signatures)
        {
            Variant[] variantSign;
            variantSign.length = sign.length;
            foreach (typeIndex, type; sign)
                variantSign[typeIndex] = Variant(type);
            variantSignatures[signIndex] = variantSign;
        }
        return Variant(variantSignatures); // array of arrays of strings
    }
    server.addMethod!(methodSignature, "system.methodSignature")();
    
    string[string][string] getCapabilities()
    {
        string[string][string] capabilities;
        void cap(string name, string specUrl, string specVersion)
        {
            capabilities[name] = ["specUrl": specUrl, "specVersion": specVersion];
        }
        cap("xmlrpc", "http://www.xmlrpc.com/spec", "1");
        cap("introspection", "http://phpxmlrpc.sourceforge.net/doc-2/ch10.html", "2");
        return capabilities;
    }
    server.addMethod!(getCapabilities, "system.getCapabilities")();
    
    // TODO: multicall
}

version (xmlrpc_unittest) unittest
{
    import xmlrpc.encoder : encodeCall;
    import xmlrpc.decoder : decodeResponse;
    import std.math : approxEqual;
    import std.typecons : tuple;
    import std.exception : assertThrown;
    import std.algorithm : canFind;
    import std.conv : to;
    import std.stdio : writeln;
    
    /*
     * Issue a request on the server instance
     */
    template call(string methodName, ReturnTypes...)
    {
        auto call(Args...)(Args args)
        {
            auto requestParams = paramsToVariantArray(args);
            auto callData = MethodCallData(methodName, requestParams);
            const requestString = encodeCall(callData);
            
            const responseString = server.handleRequest(requestString);
            
            auto responseData = decodeResponse(responseString);
            if (responseData.fault)
                throw new MethodFaultException(responseData.params[0]);
            
            static if (ReturnTypes.length == 0)
            {
                assert(responseData.params.length == 0);
                return;
            }
            else
            {
                return variantArrayToParams!(ReturnTypes)(responseData.params);
            }
        }
    }
    
    auto server = new Server();
    
    /*
     * Various combinations of the argument types and the return types are tested below.
     * This way we can be sure that the magic inside makeRawMethod() works as expected.
     */
    // Returns tuple
    auto swap(int a, int b) { return tuple(b, a); }
    server.addMethod!swap();
    auto resp1 = call!("swap", int, int)(123, 456);
    assert(resp1[0] == 456);
    assert(resp1[1] == 123);
    
    // Returns scalar
    auto doWeirdThing(real a, real b, real c) { return a * b + c; }
    server.addMethod!doWeirdThing();
    double resp2 = call!("doWeirdThing", double)(1.2, 3.4, 5.6);
    assert(approxEqual(resp2, 9.68));
    
    // Takes nothing
    auto ultimateAnswer() { return 42; }
    server.addMethod!ultimateAnswer();
    assert(call!("ultimateAnswer", int)() == 42);
    
    // Returns nothing
    void blackHole(dstring s) { assert(s == "goodbye"d); }
    server.addMethod!blackHole();
    call!"blackHole"("goodbye");
    
    // Takes nothing, returns nothing
    void nothingGetsNothingGives() { writefln("Awkward."); }
    server.addMethod!nothingGetsNothingGives();
    call!"nothingGetsNothingGives"();
    
    /*
     * Make sure that the methods can be removed properly
     */
    assert(server.removeMethod("nothingGetsNothingGives"));
    assert(!server.removeMethod("nothingGetsNothingGives"));
    
    /*
     * Error handling
     */
    int methodFaultErrorCode(Expr, size_t line = __LINE__)(lazy Expr expression)
    {
        try
            expression();
        catch (MethodFaultException ex)
            return ex.value["faultCode"].get!int();
        assert(false, to!string(line));
    }
    
    // Non-existent method
    auto errcode = methodFaultErrorCode(call!"nothingGetsNothingGives"());
    assert(errcode == FciFaultCodes.serverErrorMethodNotFound);
    
    // Wrong parameter types, non-convertible to int
    errcode = methodFaultErrorCode(call!"swap"("ck", "fu"));
    assert(errcode == FciFaultCodes.serverErrorInvalidMethodParams);
    
    // Wrong number of arguments
    errcode = methodFaultErrorCode(call!"swap"("ck", "fu", "give"));
    assert(errcode == FciFaultCodes.serverErrorInvalidMethodParams);
    
    errcode = methodFaultErrorCode(call!"swap"());
    assert(errcode == FciFaultCodes.serverErrorInvalidMethodParams);
    
    errcode = methodFaultErrorCode(call!("ultimateAnswer", int)(123, 456));
    assert(errcode == FciFaultCodes.serverErrorInvalidMethodParams);
    
    // Malformed XML
    auto responseString = server.handleRequest("I am broken XML. <phew>");
    auto responseData = decodeResponse(responseString);
    assert(responseData.fault);
    errcode = responseData.params[0]["faultCode"].get!int();
    assert(errcode == FciFaultCodes.serverErrorInvalidXmlRpc);
    
    // Application error
    void throwWeirdException() { throw new Exception("Come break me down bury me bury me"); }
    server.addMethod!throwWeirdException();
    errcode = methodFaultErrorCode(call!"throwWeirdException"());
    assert(errcode == FciFaultCodes.applicationError, to!string(errcode));
    
    // Application throws an FCI error
    void throwFciException() { throw new MethodFaultException("Hi!", 1); }
    server.addMethod!throwFciException();
    errcode = methodFaultErrorCode(call!"throwFciException"());
    assert(errcode == 1);
    
    /*
     * Introspection
     */
    auto capabilities = call!("system.getCapabilities", string[string][string])();
    assert(capabilities.length == 2);
    assert(capabilities["xmlrpc"] == ["specUrl": "http://www.xmlrpc.com/spec", "specVersion": "1"]);
    assert(capabilities["introspection"] ==
           ["specUrl": "http://phpxmlrpc.sourceforge.net/doc-2/ch10.html", "specVersion": "2"]);
    
    // Playing with one method and system.listMethods()
    assertThrown!MethodExistsException(server.addMethod!swap());
    server.removeMethod("swap");
    string[] methods = call!("system.listMethods", string[])();
    assert(!canFind(methods, "swap"));
    server.addMethod!swap("Help string for swap", [["int, int", "int", "int"]]);
    methods = call!("system.listMethods", string[])();
    assert(canFind(methods, "swap"));
    
    // Checking the help strings
    assert(call!("system.methodHelp", string)("swap") == "Help string for swap");
    assert(call!("system.methodHelp", string)("ultimateAnswer") == "");
    errcode = methodFaultErrorCode(call!("system.methodHelp", string)("noSuchMethod"));
    assert(errcode == -1);
    
    // Checking the signatures
    string[][] signatures = call!("system.methodSignature", string[][])("swap");    // Return type is string[][]
    assert(signatures == [["int, int", "int", "int"]]);
    
    string noSignature = call!("system.methodSignature", string)("ultimateAnswer"); // Return type is string
    assert(noSignature == "undef");
}
