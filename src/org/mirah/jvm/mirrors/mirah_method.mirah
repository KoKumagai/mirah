# Copyright (c) 2012 The Mirah project authors. All Rights Reserved.
# All contributing project authors may be found in the NOTICE file.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

package org.mirah.jvm.mirrors

import java.util.ArrayList
import java.util.List
import mirah.lang.ast.Position
import org.mirah.jvm.types.MemberKind
import org.mirah.typer.AssignableTypeFuture
import org.mirah.typer.DelegateFuture
import org.mirah.typer.DerivedFuture
import org.mirah.typer.ErrorType
import org.mirah.typer.ResolvedType
import org.mirah.typer.TypeFuture
import org.mirah.util.Context

class ReturnTypeFuture < AssignableTypeFuture
  def initialize(position:Position)
    super(position)
    @has_declaration = false
  end

  def setHasDeclaration(value:boolean):void
    @has_declaration = value
    checkAssignments
  end

  def hasDeclaration
    @has_declaration
  end

  def resolved(type)
    # We don't support generic methods in Mirah classes
    if type.kind_of?(MirrorType)
      type = MirrorType(MirrorType(type).erasure)
    end
    super
  end
end

class MirahMethod < AsyncMember implements MethodListener
  def initialize(context:Context, position:Position,
                 flags:int, klass:MirrorType, name:String,
                 argumentTypes:List /* of TypeFuture */,
                 returnType:TypeFuture, kind:MemberKind)
    super(flags, klass, name, argumentTypes,
          @return_type = ReturnTypeFuture.new(position), kind)
    @context = context
    @lookup = context[MethodLookup]
    @position = position
    @super_return_type = DelegateFuture.new
    @declared_return_type = returnType
    @return_type.declare(wrap(@super_return_type), position)
    @return_type.resolved(nil)
    @return_type.error_message = "Cannot determine return type."
    @error = ErrorType.new([['Does not override a method from a supertype.', @position]])
    @arity = argumentTypes.size
    setupOverrides(argumentTypes)
  end

  def wrap(target:TypeFuture):TypeFuture
    me = self
    DerivedFuture.new(target) do |resolved|
      if resolved.kind_of?(ErrorType)
        me.wrap_error(resolved)
      else
        resolved
      end
    end
  end

  def wrap_error(type:ResolvedType):ResolvedType
    JvmErrorType.new(@context, ErrorType(type))
  end

  def setupOverrides(argumentTypes:List):void
    # Should this be 'all?'?
    # It seems strange to specify some args explicitly and infer
    # others from the supertypes.
    if argumentTypes.any? {|x:AssignableTypeFuture| !x.hasDeclaration}
      declareArguments(argumentTypes)
    end
    type = MirrorType(declaringClass)
    type.addMethodListener(name, self)
    checkOverrides
  end

  def declareArguments(argumentTypes:List):void
    size = argumentTypes.size
    @arguments = DelegateFuture[size]
    size.times do |i|
      @arguments[i] = DelegateFuture.new
      @arguments[i].type = @error
      AssignableTypeFuture(argumentTypes[i]).declare(@arguments[i], @position)
    end
  end

  def methodChanged(type, name)
    checkOverrides
  end

  def checkOverrides:void
    supertype_methods = @lookup.findOverrides(
        MirrorType(declaringClass), name, @arity)
    if @arguments
      processArguments(supertype_methods)
    end
    processReturnType(supertype_methods)
  end

  def processArguments(supertype_methods:List):void
    if supertype_methods.size == 1
      method = Member(supertype_methods[0])
      @arity.times do |i|
        @arguments[i].type = method.asyncArgument(i)
      end
    else
      error = if supertype_methods.isEmpty
        @error
      else
        ErrorType.new([["Ambiguous override: #{supertype_methods}", @position]])
      end
      @arguments.each do |arg|
        arg.type = error
      end
    end
  end

  def processReturnType(supertype_methods:List):void
    filtered = ArrayList.new(supertype_methods.size)
    supertype_methods.each do |method:Member|
      match = true
      self.argumentTypes.zip(method.argumentTypes) do |a:ResolvedType, b:ResolvedType|
        next if a.isError || b.isError
        unless MirrorType(a).isSameType(MirrorType(b))
          match = false
          break
        end
      end
      filtered.add(method) if match
    end
    if filtered.isEmpty
      if @declared_return_type
        @super_return_type.type = @declared_return_type
        @return_type.setHasDeclaration(true)
      else
        @super_return_type.type = @error
        @return_type.resolved(nil)
        @return_type.setHasDeclaration(false)
      end
    else
      @return_type.setHasDeclaration(true)
      future = OverrideFuture.new
      if @declared_return_type
        future.addType(@declared_return_type)
      end
      filtered.each do |m:Member|
        future.addType(m.asyncReturnType)
      end
      future.addType(Member(supertype_methods[0]).asyncReturnType)
      @super_return_type.type = future
    end
  end
end