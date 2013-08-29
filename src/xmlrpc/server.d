/*
 * XMLRPC server
 * Pavel Kirienko, 2013 (pavel.kirienko@gmail.com)
 */

module xmlrpc.server;

import xmlrpc.encoder : encodeResponse;
import xmlrpc.decoder : decodeCall;
import xmlrpc.data : MethodCallData, MethodResponseData;
import xmlrpc.paramconv : paramsToVariantArray, variantArrayToParams;
import xmlrpc.exception : XmlRpcException;
import std.exception : enforce;
import std.variant : Variant;
import std.stdio : writefln;
import std.traits : isCallable, ParameterTypeTuple, ReturnType;
import std.typecons : Tuple, tuple;

alias void delegate(string) LogHandler;
alias Variant[] delegate(Variant[]) RawMethodHandler;

class Server
{
    this(LogHandler logHandler = null, bool addIntrospectionMethods = false)
    {
        if (!logHandler)
            logHandler = (string msg) { import std.cstream; derr.write(msg ~ "\n"); };
        logHandler_ = logHandler;
        if (addIntrospectionMethods)
            this.addIntrospectionMethods();
    }
    
    string handleRequest(string encodedRequest)
    {
        try
        {
            auto callData = decodeCall(encodedRequest);
            
            debug (xmlrpc)
                writefln("server <== %s", callData.toString());
            
            auto methodPointer = callData.name in methods_;
            enforce(methodPointer);  // TODO: Proper handler
            
            MethodResponseData responseData;
            responseData.params = (*methodPointer)(callData.params);
            
            debug (xmlrpc)
                writefln("server ==> %s", responseData.toString());
            
            return encodeResponse(responseData);
        }
        catch (Exception ex)
        {
            // TODO: add FCI
            throw ex;
        }
    }
    
    void addRawMethod(RawMethodHandler handler, string name)
    {
        enforce(name.length, "Method name must not be empty");
        if (name in methods_)
            throw new MethodExistsException(name);
        methods_[name] = handler;
        debug (xmlrpc)
            writefln("New method: %s", name);
    }
    
    bool removeMethod(string name)
    {
        return methods_.remove(name);
    }
    
    void addIntrospectionMethods()
    {
        // TODO
        introspecting_ = true;
    }
    
    @property void logHandler(LogHandler lh) { logHandler_ = lh; }
    @property LogHandler logHandler() { return logHandler_; }
    
    @property bool introspecting() const { return introspecting_; }
    
private:
    LogHandler logHandler_;
    bool introspecting_;
    RawMethodHandler[string] methods_;
}

class MethodExistsException : XmlRpcException
{
    private this(string methodName, string file = __FILE__, size_t line = __LINE__)
    {
        this.methodName = methodName;
        super("Method already exists: " ~ methodName, file, line);
    }
    
    string methodName;
}

/**
 * We can't use member function here because that doesn't work with local handlers:
 * Error: template instance addMethod!(method) cannot use local 'method' as parameter to non-global template <...>
 */
void addMethod(alias method, string name = __traits(identifier, method))(Server server)
{
    static assert(name.length, "Method name must not be empty");
    auto handler = makeRawMethod!method();
    server.addRawMethod(handler, name);
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
    
    return (Variant[] inputVariant)  // Well, the life is getting tough now.
    {
        // Input resolution
        static if (Input.length == 0)
        {
            enforce(inputVariant.length == 0); // TODO: throw proper exception
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
            Input input = variantArrayToParams!(Input)(inputVariant);
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

version (xmlrpc_unittest) unittest
{
    import xmlrpc.encoder : encodeCall;
    import xmlrpc.decoder : decodeResponse;
    import std.math : approxEqual;
    import std.exception : assertThrown;
    
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
            assert(!responseData.fault); // TODO: throw
            static if (ReturnTypes.length == 0)
            {
                return responseData.params;
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
    auto doWierdThing(real a, real b, real c) { return a * b + c; }
    server.addMethod!doWierdThing();
    double resp2 = call!("doWierdThing", double)(1.2, 3.4, 5.6);
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
    assertThrown(call!"nothingGetsNothingGives"());
}