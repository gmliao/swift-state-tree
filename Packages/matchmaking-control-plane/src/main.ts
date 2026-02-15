import { ValidationPipe } from '@nestjs/common';
import { NestFactory } from '@nestjs/core';
import { DocumentBuilder, SwaggerModule } from '@nestjs/swagger';
import { AppModule } from './app.module';

/**
 * Bootstrap the NestJS application with validation and Swagger documentation.
 */
async function bootstrap() {
  const app = await NestFactory.create(AppModule);
  app.useGlobalPipes(
    new ValidationPipe({
      whitelist: true,
      forbidNonWhitelisted: true,
      transform: true,
    }),
  );

  const config = new DocumentBuilder()
    .setTitle('Matchmaking Control Plane API')
    .setDescription(
      'Matchmaking queue management, assignment lifecycle, and JWT issuance for game server connections.',
    )
    .setVersion('1.0')
    .addTag('matchmaking', 'Enqueue, cancel, and poll ticket status')
    .addTag('provisioning', 'Game server registration')
    .addTag('health', 'Health check')
    .addTag('jwks', 'JSON Web Key Set for JWT validation')
    .build();
  const document = SwaggerModule.createDocument(app, config);
  SwaggerModule.setup('api', app, document);

  await app.listen(process.env.PORT ?? 3000);
}
bootstrap();
